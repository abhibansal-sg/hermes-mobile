"""Resource sampler for I6 (resource bounds / leak detection).

Samples the relay subprocess's RSS, open-FD count, and thread count every N
seconds via ``psutil``, recording a time series (the "resource curve" the report
embeds). At scenario end it fits a least-squares line to RSS and FD and flags
MONOTONIC GROWTH: a positive slope whose total extrapolated growth over the run
exceeds a threshold. A bounded relay's RSS/FD should oscillate around a steady
state (ring eviction, connection churn), not climb without bound.

The sampler runs in a background thread so it never contends with the asyncio
loop driving load. Sampling is ``nice``-friendly (sleeps most of the time) — the
QA-3 swarm shares this machine.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Optional

_log = logging.getLogger("soak.resources")

try:
    import psutil  # type: ignore
except Exception:  # pragma: no cover - psutil missing degrades to no sampling
    psutil = None  # type: ignore


@dataclass
class Sample:
    t: float          # seconds since sampling started
    rss_mib: float
    num_fds: int
    num_threads: int


@dataclass
class GrowthVerdict:
    metric: str
    slope_per_s: float        # least-squares slope
    total_growth: float       # slope * duration (extrapolated over the run)
    first: float
    last: float
    n: int
    leaked: bool              # True if monotonic growth exceeds threshold

    def as_dict(self) -> dict:
        return {
            "metric": self.metric, "slope_per_s": round(self.slope_per_s, 6),
            "total_growth": round(self.total_growth, 3),
            "first": round(self.first, 3), "last": round(self.last, 3),
            "n": self.n, "leaked": self.leaked,
        }


def _least_squares_slope(xs: list[float], ys: list[float]) -> float:
    """Slope of the least-squares fit of ys vs xs (0.0 when degenerate)."""
    n = len(xs)
    if n < 2:
        return 0.0
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return 0.0
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return sxy / sxx


class ResourceSampler:
    """Background RSS/FD/thread sampler for one relay PID."""

    def __init__(
        self,
        pid: int,
        *,
        interval_s: float = 30.0,
        # Monotonic-growth thresholds (I6). RSS: flag if extrapolated growth
        # over the run exceeds 64 MiB AND the last sample is >25% above the
        # first (a few-MiB drift on a healthy relay is normal warmup). FD: flag
        # if the FD count grows by more than 32 over the run with a positive
        # slope (each leaked socket/connection shows up as an FD).
        rss_growth_mib: float = 64.0,
        fd_growth: float = 32.0,
    ) -> None:
        self.pid = pid
        self.interval_s = interval_s
        self.rss_growth_mib = rss_growth_mib
        self.fd_growth = fd_growth
        self.samples: list[Sample] = []
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._proc = None
        if psutil is not None:
            try:
                self._proc = psutil.Process(pid)
            except psutil.Error:
                self._proc = None

    # -- lifecycle --------------------------------------------------------
    def start(self) -> None:
        if self._proc is None:
            _log.warning("psutil unavailable or pid %d gone; I6 sampling off", self.pid)
            return
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name="soak-resource-sampler")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
            self._thread = None

    def repoint(self, pid: int) -> None:
        """After a relay restart the PID changes — re-target the sampler (T4)."""
        self.pid = pid
        if psutil is not None:
            try:
                self._proc = psutil.Process(pid)
            except psutil.Error:
                self._proc = None

    def _run(self) -> None:
        t0 = time.monotonic()
        while not self._stop.is_set():
            self._sample_once(t0)
            self._stop.wait(self.interval_s)

    def _sample_once(self, t0: float) -> None:
        proc = self._proc
        if proc is None:
            return
        try:
            with proc.oneshot():
                rss_mib = proc.memory_info().rss / (1024 * 1024)
                try:
                    num_fds = proc.num_fds()
                except (psutil.Error, AttributeError):
                    num_fds = -1  # num_fds unsupported on this platform
                num_threads = proc.num_threads()
            self.samples.append(Sample(
                t=round(time.monotonic() - t0, 3),
                rss_mib=round(rss_mib, 3), num_fds=num_fds,
                num_threads=num_threads,
            ))
        except psutil.Error:
            _log.debug("sample failed (relay mid-restart?)", exc_info=True)

    # -- analysis ---------------------------------------------------------
    def _verdict(self, metric: str, ys: list[float], xs: list[float],
                 threshold: float) -> GrowthVerdict:
        slope = _least_squares_slope(xs, ys)
        duration = (xs[-1] - xs[0]) if len(xs) > 1 else 0.0
        total = slope * duration
        first, last = (ys[0], ys[-1]) if ys else (0.0, 0.0)
        leaked = (slope > 0) and (total > threshold)
        return GrowthVerdict(metric, slope, total, first, last, len(ys), leaked)

    def analyze(self) -> dict:
        """Fit growth on RSS + FD; return verdicts + the raw curve."""
        xs = [s.t for s in self.samples]
        rss = [s.rss_mib for s in self.samples]
        fds = [float(s.num_fds) for s in self.samples if s.num_fds >= 0]
        fds_x = [s.t for s in self.samples if s.num_fds >= 0]
        rss_v = self._verdict("rss_mib", rss, xs, self.rss_growth_mib)
        fd_v = self._verdict("num_fds", fds, fds_x, self.fd_growth)
        return {
            "pid": self.pid,
            "n_samples": len(self.samples),
            "interval_s": self.interval_s,
            "rss": rss_v.as_dict(),
            "fd": fd_v.as_dict(),
            "leaked": rss_v.leaked or fd_v.leaked,
            "curve": [
                {"t": s.t, "rss_mib": s.rss_mib, "num_fds": s.num_fds,
                 "num_threads": s.num_threads}
                for s in self.samples
            ],
        }
