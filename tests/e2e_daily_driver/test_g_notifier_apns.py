"""Scenario (g) — mock-APNs notifier incl. foreground suppression (A8).

A8 is the notification contract: the notifier fires on turn-complete / approval
/ clarify / task-complete for OWNED sessions, suppressed when the phone holds
the session foregrounded. Blocking gates (approval/clarify) BYPASS the
foreground gate — the turn is stalled on the user, so they always ring.

This is the device-shaped A8 assertion. Rather than drive the relay subprocess
and try to introspect APNs calls (which the relay does not expose), we run the
REAL ``Reframer`` + REAL ``Notifier`` IN-PROCESS, fed by a REAL mock-gateway
event stream. The push sink is a ``FakePush`` recording ``notify()`` calls —
the same pattern as ``relay/tests/test_notifier.py``, but the frames are real
reframer output driven by the mock gateway's deterministic scripts, not hand-
built. That makes this an integration slice that closes A8 end-to-end.

Hermetic: zero network, zero real APNs.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path
from typing import Any

import pytest

# Bring the relay package + mock gateway onto the path for in-process use.
_BRANCH_ROOT = Path(__file__).resolve().parents[2]
_RELAY_DIR = _BRANCH_ROOT / "relay"
sys.path.insert(0, str(_RELAY_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent / "mock_gateway"))

from hermes_relay.durable_state import DurableState  # noqa: E402
from hermes_relay.notifier import Notifier, NotifierConfig  # noqa: E402
from hermes_relay.reframer import Reframer  # noqa: E402
from hermes_relay.session_state import SessionStore  # noqa: E402
from hermes_relay.types import GatewayEvent  # noqa: E402

pytestmark = pytest.mark.asyncio


# ---------------------------------------------------------------------------
# Fakes + harness helpers.
# ---------------------------------------------------------------------------


class FakePush:
    """Records every notify() call — the mock APNs sender (no network)."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def notify(self, event_type, title, body, payload=None, *, category=None,
               expiration=0, collapse_id=None) -> int:
        self.calls.append({
            "event_type": event_type, "title": title, "body": body,
            "payload": payload, "category": category, "expiration": expiration,
            "collapse_id": collapse_id,
        })
        return 1


class FakeGateway:
    """Stands in for GatewayClient.owns() — owns every session in these tests."""

    def owns(self, sid: str) -> bool:
        return True


async def drive_script_through_notifier(
    mock_gateway,
    *,
    script: str,
    foregrounded: bool,
    durable_path: Path,
    **script_kwargs: Any,
) -> tuple[list[dict[str, Any]], dict[str, int], str]:
    """Drive one mock-gateway script through REAL reframer + REAL notifier.

    Returns (push_descriptors, notifier_metrics, session_id).

    The ``foregrounded`` flag declares whether the phone holds THIS session
    foregrounded for the duration of the turn (the §6 gate signal).
    """
    push = FakePush()
    durable = DurableState(durable_path)
    notifier = Notifier(
        NotifierConfig(), _null_bus(), FakeGateway(),
        is_foregrounded=lambda sid, _fg={}: sid in _fg,
        push_engine=push, durable=durable,
    )
    fg_set: set[str] = set()
    # Patch the notifier's foreground oracle after construction so we can
    # mutate ``fg_set`` during the drive.
    notifier._is_foregrounded = lambda sid: sid in fg_set  # type: ignore[assignment]

    reframer = Reframer(_null_bus(), SessionStore())

    from mock_gateway.server import create_scripted_session
    # For interactive scripts (approval/clarify), shrink the bounded wait so
    # the in-process drive (no phone answering) terminates in <1s instead of 8s.
    kwargs = dict(script_kwargs)
    kwargs.setdefault("wait_timeout_s", 0.3)
    sid = await create_scripted_session(mock_gateway, script=script, **kwargs)
    if foregrounded:
        fg_set.add(sid)

    captured: list[dict[str, Any]] = []
    orig_broadcast = mock_gateway._broadcast

    async def tap(sid_: str, params: dict[str, Any]) -> None:
        ge = GatewayEvent(
            type=params.get("type", ""),
            session_id=sid_,
            payload=dict(params.get("payload") or {}),
        )
        for frame in reframer.reframe(ge):
            descriptor = notifier.observe(frame)
            if descriptor is not None:
                captured.append(descriptor)
        await asyncio.sleep(0)  # yield

    mock_gateway._broadcast = tap  # type: ignore[assignment]
    try:
        sess = mock_gateway.sessions[sid]
        await mock_gateway._run_script(sess)
    finally:
        mock_gateway._broadcast = orig_broadcast  # type: ignore[assignment]

    metrics = {
        "fired": notifier.metrics.fired,
        "suppressed_foreground": notifier.metrics.suppressed_foreground,
        "suppressed_dedupe": notifier.metrics.suppressed_dedupe,
    }
    return captured, metrics, sid


def _null_bus():
    """A bus the notifier never actually pumps (we drive observe() directly)."""
    from hermes_relay.bus import EventBus
    return EventBus()


# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------


async def test_turn_complete_fires_when_backgrounded(mock_gateway, tmp_path, evidence):
    captured, metrics, sid = await drive_script_through_notifier(
        mock_gateway,
        script="simple",
        foregrounded=False,
        durable_path=tmp_path / "bg.sqlite3",
        text="Backgrounded turn finishes.",
    )
    turn_pushes = [c for c in captured if c["event_type"] == "turn_complete"]
    assert len(turn_pushes) == 1, (
        f"turn_complete must fire when backgrounded: captured={captured}"
    )
    assert turn_pushes[0]["sid"] == sid

    evidence("g-turn-backgrounded", {
        "session_id": sid,
        "fired": [c["event_type"] for c in captured],
        "metrics": metrics,
    })


async def test_turn_complete_suppressed_when_foregrounded(mock_gateway, tmp_path, evidence):
    captured, metrics, sid = await drive_script_through_notifier(
        mock_gateway,
        script="simple",
        foregrounded=True,
        durable_path=tmp_path / "fg.sqlite3",
        text="Foregrounded turn finishes silently.",
    )
    turn_pushes = [c for c in captured if c["event_type"] == "turn_complete"]
    assert turn_pushes == [], (
        f"turn_complete must NOT fire when foregrounded: captured={captured}"
    )
    assert metrics["suppressed_foreground"] >= 1, (
        f"foreground suppression counter did not advance: {metrics}"
    )

    evidence("g-turn-foreground-suppressed", {
        "session_id": sid,
        "fired": [c["event_type"] for c in captured],
        "metrics": metrics,
    })


async def test_approval_always_fires_even_foregrounded(mock_gateway, tmp_path, evidence):
    """§6: approval is a blocking gate — bypasses the foreground suppression."""
    captured, metrics, sid = await drive_script_through_notifier(
        mock_gateway,
        script="approval",
        foregrounded=True,
        durable_path=tmp_path / "appr.sqlite3",
    )
    appr = [c for c in captured if c["event_type"] == "approval"]
    assert len(appr) == 1, (
        f"approval must ring even when foregrounded: captured={captured}"
    )

    evidence("g-approval-bypass", {
        "session_id": sid,
        "fired": [c["event_type"] for c in captured],
        "foregrounded_during_run": True,
        "metrics": metrics,
    })


async def test_clarify_always_fires_even_foregrounded(mock_gateway, tmp_path, evidence):
    """§6: clarify is a blocking gate — bypasses the foreground suppression."""
    captured, metrics, sid = await drive_script_through_notifier(
        mock_gateway,
        script="clarify",
        foregrounded=True,
        durable_path=tmp_path / "clar.sqlite3",
    )
    clar = [c for c in captured if c["event_type"] == "clarify"]
    assert len(clar) == 1, (
        f"clarify must ring even when foregrounded: captured={captured}"
    )

    evidence("g-clarify-bypass", {
        "session_id": sid,
        "fired": [c["event_type"] for c in captured],
        "foregrounded_during_run": True,
        "metrics": metrics,
    })


async def test_task_complete_fires_backgrounded_suppressed_foregrounded(
    mock_gateway, tmp_path, evidence,
):
    """task_complete fires once when backgrounded; suppressed when foregrounded."""
    # Backgrounded drive: task_complete fires once.
    captured_bg, metrics_bg, sid_bg = await drive_script_through_notifier(
        mock_gateway,
        script="tasklist",
        foregrounded=False,
        durable_path=tmp_path / "task_bg.sqlite3",
    )
    task_pushes_bg = [c for c in captured_bg if c["event_type"] == "task_complete"]
    assert len(task_pushes_bg) == 1, (
        f"task_complete must fire when backgrounded: captured={captured_bg}"
    )

    # Foregrounded drive: task_complete suppressed.
    captured_fg, metrics_fg, sid_fg = await drive_script_through_notifier(
        mock_gateway,
        script="tasklist",
        foregrounded=True,
        durable_path=tmp_path / "task_fg.sqlite3",
    )
    task_pushes_fg = [c for c in captured_fg if c["event_type"] == "task_complete"]
    assert task_pushes_fg == [], (
        f"task_complete must be suppressed when foregrounded: captured={captured_fg}"
    )
    assert metrics_fg["suppressed_foreground"] >= 1, (
        f"foreground suppression counter did not advance: {metrics_fg}"
    )

    evidence("g-task-complete-both-modes", {
        "background_session_id": sid_bg,
        "foreground_session_id": sid_fg,
        "background_fired": [c["event_type"] for c in captured_bg],
        "foreground_fired": [c["event_type"] for c in captured_fg],
        "background_metrics": metrics_bg,
        "foreground_metrics": metrics_fg,
    })
