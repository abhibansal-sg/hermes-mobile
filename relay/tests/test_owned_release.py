"""O1 owned-session release — regression for the soak handoff finding.

GatewayClient._owned grew once per unique driven session forever in-process
(``_unmark_owned`` had zero callers): reconnect re-establishment fanned a
``session.resume`` over every session the relay had EVER driven, and the
Notifier's owned-session set never shrank — the accumulating
``owned_sessions`` observed on the live relay.

The fix (gateway_client.py ``_trim_owned``) releases idle ownership: a TTL
(72 h) is the primary bound, a soft cap (4096) backstops churn storms but
never evicts an entry younger than the min-idle floor (30 min) — every
create/resume/submit re-marks, so a live turn's ownership is always fresh.
Eviction downgrades SAFELY to resume: the downstream SUBMIT path re-resumes
whenever ``owns()`` is False (downstream.py), which re-marks — a released
session re-owns on next use.

These tests FAIL on origin/main (``_owned_at`` does not exist and nothing
ever shrinks ``_owned``) and PASS with the bound.
"""

from __future__ import annotations

import time

import hermes_relay.gateway_client as gc
from hermes_relay.bus import EventBus
from hermes_relay.gateway_client import GatewayClient, GatewayConfig


class RecordingDurable:
    """Fake durable mirror: records owned-session add/remove."""

    def __init__(self, seed: set[str] = frozenset()) -> None:
        self.owned = set(seed)
        self.added: list[str] = []
        self.removed: list[str] = []

    def load_owned_sessions(self) -> set[str]:
        return set(self.owned)

    def add_owned_session(self, sid: str) -> None:
        self.owned.add(sid)
        self.added.append(sid)

    def remove_owned_session(self, sid: str) -> None:
        if sid in self.owned:
            self.owned.discard(sid)
            self.removed.append(sid)


def _client(durable=None) -> GatewayClient:
    return GatewayClient(GatewayConfig(), EventBus(), durable=durable)


def _age(client: GatewayClient, sid: str, seconds: float) -> None:
    """Backdate ``sid``'s mark so the idle bound sees it as old."""
    client._owned_at[sid] = time.monotonic() - seconds


def test_idle_ownership_released_past_ttl() -> None:
    """Sessions idle past the TTL drop out of the owned set; fresh ones
    survive (fail-before: AttributeError — no _owned_at, nothing releases).
    TTL-relative (reads the constant) so a TTL bump never breaks this."""
    c = _client()
    for i in range(3):
        c._mark_owned(f"s{i}")
    _age(c, "s0", gc._OWNED_RELEASE_IDLE_S + 3600)
    _age(c, "s1", gc._OWNED_RELEASE_IDLE_S + 3600)
    c._mark_owned("s3")  # a mark runs the release pass
    assert c.owns("s0") is False, "a past-TTL idle session is still owned"
    assert c.owns("s1") is False
    assert c.owns("s2") and c.owns("s3")
    assert "s0" not in c.owned_sessions


def test_release_mirrors_to_durable() -> None:
    """Releasing an origin id also removes its durable row (the sqlite
    ``owned_sessions`` table must not accumulate either)."""
    d = RecordingDurable()
    c = _client(d)
    c._mark_owned("s0")
    _age(c, "s0", gc._OWNED_RELEASE_IDLE_S + 3600)
    c._mark_owned("s1")
    assert "s0" in d.removed
    assert c.owns("s0") is False


def test_cap_evicts_oldest_but_pins_fresh(monkeypatch) -> None:
    """Over the cap, the OLDEST idle entries release first — but an entry
    younger than the min-idle floor is NEVER evicted (a live turn's mark is
    always that fresh)."""
    monkeypatch.setattr(gc, "_OWNED_CAP", 4)
    c = _client()
    for i in range(8):
        c._mark_owned(f"s{i}")
        _age(c, f"s{i}", 2 * 3600)  # idle 2 h: past the floor, under the TTL
    assert len(c._owned) <= 4, "the cap backstop did not trim idle entries"
    # The newest idle entries survived the oldest-first eviction.
    assert c.owns("s7") and not c.owns("s0")

    # A FRESH entry is pinned even while over the cap.
    monkeypatch.setattr(gc, "_OWNED_CAP", 2)
    fresh = _client()
    for i in range(5):
        fresh._mark_owned(f"f{i}")  # all age ~0: younger than the floor
    assert len(fresh._owned) == 5, "fresh (mid-turn-fresh) entries were evicted"


def test_release_prunes_live_id_remap() -> None:
    """Releasing an origin also drops its connection-local live id and the
    origin->live remap (``live_id_for`` falls back to identity)."""
    c = _client()
    c._mark_owned("origin-1")
    # Simulate session_resume learning a DISTINCT live id (in-memory only).
    c._owned.add("live-1")
    c._owned_at["live-1"] = c._owned_at["origin-1"]
    c._live_by_origin["origin-1"] = "live-1"
    c._live_by_origin["live-1"] = "live-1"
    _age(c, "origin-1", gc._OWNED_RELEASE_IDLE_S + 3600)
    _age(c, "live-1", gc._OWNED_RELEASE_IDLE_S + 3600)
    c._mark_owned("other")
    assert not c.owns("origin-1") and not c.owns("live-1")
    assert "origin-1" not in c._live_by_origin
    assert "live-1" not in c._live_by_origin
    assert c.live_id_for("origin-1") == "origin-1"  # remap forgotten


def test_durable_seeded_sessions_start_fresh() -> None:
    """Sessions re-loaded from durable storage on boot get a full TTL before
    the first release pass (they are the phone's live sessions)."""
    d = RecordingDurable(seed={"seeded"})
    c = _client(d)
    assert c.owns("seeded")
    c._mark_owned("new")  # runs the release pass
    assert c.owns("seeded"), "a durable-seeded session was trimmed at boot"


def test_released_session_reowns_on_next_drive() -> None:
    """The degrade-to-resume round trip: after release ``owns()`` is False —
    exactly the gate downstream's SUBMIT path uses to re-resume — and the
    re-drive (what session_resume/prompt_submit do) re-marks it owned."""
    c = _client()
    c._mark_owned("s0")
    _age(c, "s0", gc._OWNED_RELEASE_IDLE_S + 3600)
    c._mark_owned("s1")
    assert c.owns("s0") is False  # downstream.py would session_resume here
    c._mark_owned("s0")           # ...and the resume/submit re-marks
    assert c.owns("s0") is True
