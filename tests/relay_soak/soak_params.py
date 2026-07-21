"""Duration / seed / mode parameterization for the soak scenarios.

Every scenario is parameterized by ``(duration, seed)`` per the spec. Two named
modes:

* ``short`` — 2-5 min per scenario (CI gate). Fast enough to run the whole
  matrix on every relay change, long enough to exercise reconnect/kill windows.
* ``soak``  — the spec's full durations (T4 kill-loop 1h, T7 marathon 4h+, …).
  Run overnight against a relay tip.

A ``SOAK_SCALE`` env var multiplies every duration (default 1.0). The harness
self-proof runs at ``SOAK_SCALE=0.1`` so the whole short matrix executes in a
few minutes while still exercising every code path and every invariant. This is
also the CPU-discipline lever: the QA-3 swarm shares this machine, so soak
durations are compressible without touching scenario logic.

Seed: ``SOAK_SEED`` (default 0) drives every randomized behavior so runs are
reproducible; each scenario derives its own ``random.Random(seed ^ salt)``.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def mode() -> str:
    """``short`` (default) or ``soak`` — from ``SOAK_MODE``."""
    m = os.environ.get("SOAK_MODE", "short").strip().lower()
    return "soak" if m == "soak" else "short"


def scale() -> float:
    """Global duration multiplier (``SOAK_SCALE``, default 1.0, clamped >0)."""
    return max(_env_float("SOAK_SCALE", 1.0), 0.01)


def seed() -> int:
    """Master RNG seed (``SOAK_SEED``, default 0)."""
    return _env_int("SOAK_SEED", 0)


@dataclass(frozen=True)
class ScenarioParams:
    """Resolved duration + intensity knobs for one scenario."""

    name: str
    duration_s: float       # wall-clock the scenario drives load
    seed: int
    # Scenario-specific intensity (interpreted per scenario):
    n_sessions: int = 1     # T3 concurrent sessions
    n_kills: int = 1        # T4 relay kill count (bounded by duration too)
    n_flaps: int = 1        # T2 foreground flap count target

    def scaled(self, seconds: float) -> float:
        """Apply the global SOAK_SCALE to a base duration."""
        return max(seconds * scale(), 1.0)


# Base durations per scenario, per mode (seconds before SOAK_SCALE).
# short: 2-5 min each (CI). soak: spec durations.
_BASE = {
    #                 short   soak
    "t1_churn":       (150.0, 1800.0),    # T1 connect churn
    "t2_flap":        (120.0, 1800.0),    # T2 foreground flap storm
    "t3_multi":       (150.0, 1800.0),    # T3 multi-session interleave
    "t4_kill":        (180.0, 3600.0),    # T4 kill loop (1h soak)
    "t5_gateway":     (150.0, 1800.0),    # T5 gateway abuse (S8 class)
    "t6_fuzz":        (120.0, 1800.0),    # T6 fuzz (hypothesis)
    "t7_marathon":    (240.0, 14400.0),   # T7 marathon (4h+ soak)
    "t8_ring":        (120.0, 1800.0),    # T8 replay-ring boundaries
}


def params(name: str, *, n_sessions: int = 1, n_kills: int = 1,
           n_flaps: int = 1) -> ScenarioParams:
    """Resolve a scenario's parameters for the active mode + scale."""
    short_s, soak_s = _BASE[name]
    base = soak_s if mode() == "soak" else short_s
    return ScenarioParams(
        name=name,
        duration_s=max(base * scale(), 1.0),
        seed=seed(),
        n_sessions=n_sessions,
        n_kills=n_kills,
        n_flaps=n_flaps,
    )
