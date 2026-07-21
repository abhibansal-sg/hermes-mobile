"""Extended synthetic phone-driver for soak torture.

Built on ``tests/e2e_daily_driver/phone_driver.py::PhoneDriver`` (the ratified
relay<->phone protocol). Adds:

* **generation tagging** — every received frame is tagged with the connection
  generation it arrived on, so the I3 checker can test per-connection seq
  coverage (seq is per-CONNECTION, restarting at 1 on each reconnect);
* **fault-injection shim** — an optional ``drop_if`` predicate that discards
  selected downstream frames BEFORE the invariant checkers see them, simulating
  a frame lost on the wire to the phone (used by the injected-fault self-proof);
* **torture behaviors** — connect churn, foreground flap, ack storms, cursor
  manipulation, and multi-connection factories, each a stoppable coroutine
  seeded for reproducibility.

NEVER touches a live gateway/relay — only the isolated relay downstream port the
scenario wired up.
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
from typing import Any, Callable, Optional

import websockets

# Reuse the ratified driver verbatim.
from phone_driver import PhoneDriver, PhoneFrame  # noqa: F401  (re-exported)

_log = logging.getLogger("soak.phone_ext")

DropPredicate = Callable[[PhoneFrame], bool]


class SoakPhoneDriver(PhoneDriver):
    """PhoneDriver + per-generation tagging + a wire-loss fault shim.

    ``drop_if(frame) -> True`` discards that frame from the recorded log (and
    counts it in ``dropped``) — the phone "never received" it. This is the shim
    the injected-fault proof uses to show the invariant checkers actually detect
    loss (rather than passing vacuously).
    """

    def __init__(self, url: str, *, token: str = "",
                 drop_if: Optional[DropPredicate] = None) -> None:
        super().__init__(url, token=token)
        self.generation = 0
        self._frame_gen: list[int] = []      # parallel to self.frames
        self.drop_if = drop_if
        self.dropped: list[PhoneFrame] = []

    # -- lifecycle (tag generation before the reader can append) ----------
    async def connect(self) -> None:
        headers = {"Authorization": f"Bearer {self._token}"} if self._token else None
        self._closed.clear()
        self._ws = await websockets.connect(
            self._url, max_size=8 * 1024 * 1024, additional_headers=headers,
        )
        self.generation += 1
        self._reader = asyncio.create_task(self._read_loop())

    # -- reader: base parsing + generation tag + fault shim ---------------
    async def _read_loop(self) -> None:
        ws = self._ws
        if ws is None:
            return
        gen = self.generation
        try:
            async for raw in ws:
                for line in str(raw).splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if "id" in msg and msg["id"] in self._pending:
                        fut = self._pending.pop(msg["id"])
                        if not fut.done():
                            fut.set_result(msg)
                    elif "kind" in msg:
                        frame = PhoneFrame.from_wire(msg)
                        if self.drop_if is not None and self.drop_if(frame):
                            self.dropped.append(frame)
                            continue
                        self.frames.append(frame)
                        self._frame_gen.append(gen)
        except Exception as e:  # noqa: BLE001
            _log.debug("soak phone reader stopped: %r", e)

    # -- generation-aware views ------------------------------------------
    def generation_segments(self) -> list[list[PhoneFrame]]:
        """Frames grouped by the connection generation they arrived on."""
        segs: dict[int, list[PhoneFrame]] = {}
        for frame, gen in zip(self.frames, self._frame_gen):
            segs.setdefault(gen, []).append(frame)
        return [segs[g] for g in sorted(segs)]

    # -- raw upstream (fuzzing — bypass the typed helpers) ----------------
    async def send_raw(self, data: str) -> None:
        """Send an arbitrary (possibly malformed) upstream payload (T6)."""
        assert self._ws is not None
        await self._ws.send(data)


# ---------------------------------------------------------------------------
# Torture behaviors — each runs until ``stop`` is set or the deadline passes.
# All take an explicit ``random.Random`` so runs are reproducible per seed.
# ---------------------------------------------------------------------------


async def churn_loop(
    make_phone: Callable[[], Any],
    driver: SoakPhoneDriver,
    *,
    stop: asyncio.Event,
    rng: random.Random,
    lo_s: float = 0.1,
    hi_s: float = 5.0,
    on_reconnect: Optional[Callable[[SoakPhoneDriver], Any]] = None,
) -> int:
    """T1: close + reconnect the driver at randomized intervals.

    Returns the number of churn cycles completed. ``on_reconnect`` (optional)
    runs after each reconnect (e.g. to resync from the last seq).
    """
    cycles = 0
    while not stop.is_set():
        await asyncio.sleep(rng.uniform(lo_s, hi_s))
        if stop.is_set():
            break
        try:
            await driver.close()
        except Exception:  # noqa: BLE001
            pass
        await asyncio.sleep(rng.uniform(0.02, 0.2))
        try:
            await driver.connect()
        except Exception:  # noqa: BLE001
            _log.debug("churn reconnect failed", exc_info=True)
            continue
        cycles += 1
        if on_reconnect is not None:
            try:
                res = on_reconnect(driver)
                if asyncio.iscoroutine(res):
                    await res
            except Exception:  # noqa: BLE001
                _log.debug("churn on_reconnect failed", exc_info=True)
    return cycles


async def foreground_flap_loop(
    driver: SoakPhoneDriver,
    session_id: str,
    *,
    stop: asyncio.Event,
    rng: random.Random,
    lo_s: float = 0.02,
    hi_s: float = 0.3,
) -> int:
    """T2: rapid foreground(session)/foreground(null) transitions.

    Returns the number of flaps. Exercises the §6 foreground gate + the
    reconnect single-flight path under rapid set-replace churn.
    """
    flaps = 0
    fg = True
    while not stop.is_set():
        await asyncio.sleep(rng.uniform(lo_s, hi_s))
        if stop.is_set():
            break
        try:
            await driver.foreground(session_id if fg else None)
        except Exception:  # noqa: BLE001
            _log.debug("flap foreground failed", exc_info=True)
            continue
        fg = not fg
        flaps += 1
    return flaps


async def ack_storm_loop(
    driver: SoakPhoneDriver,
    *,
    stop: asyncio.Event,
    rng: random.Random,
    lo_s: float = 0.01,
    hi_s: float = 0.1,
) -> int:
    """T8: ack{through} at the current head at high frequency.

    Returns the number of acks sent. Hammers the ring's ack-eviction path.
    """
    acks = 0
    while not stop.is_set():
        await asyncio.sleep(rng.uniform(lo_s, hi_s))
        if stop.is_set():
            break
        head = max((f.seq for f in driver.frames), default=0)
        # Occasionally ack a STALE/ancient watermark (the ring must ignore it).
        through = rng.choice([head, max(0, head - rng.randint(0, 50)), 0])
        try:
            await driver.ack(through)
        except Exception:  # noqa: BLE001
            _log.debug("ack storm failed", exc_info=True)
            continue
        acks += 1
    return acks


async def cursor_manipulation_loop(
    driver: SoakPhoneDriver,
    *,
    stop: asyncio.Event,
    rng: random.Random,
    lo_s: float = 0.05,
    hi_s: float = 0.5,
) -> int:
    """T8: resync from adversarial cursors (0, head, ancient, FAR future).

    Returns the number of resyncs. A future cursor (> head) must trigger the
    snapshot-all-sessions heal (downstream.py:192-203), not a crash or a
    silent no-catch-up.
    """
    resyncs = 0
    while not stop.is_set():
        await asyncio.sleep(rng.uniform(lo_s, hi_s))
        if stop.is_set():
            break
        head = max((f.seq for f in driver.frames), default=0)
        last_seq = rng.choice([
            0,                                   # cold: snapshot everything
            head,                                # current: attach live
            max(0, head - rng.randint(1, 20)),   # small gap: replay
            head + rng.randint(100, 100000),     # FAR future: snapshot heal
        ])
        try:
            await driver.resync(last_seq)
        except Exception:  # noqa: BLE001
            _log.debug("cursor manipulation failed", exc_info=True)
            continue
        resyncs += 1
    return resyncs
