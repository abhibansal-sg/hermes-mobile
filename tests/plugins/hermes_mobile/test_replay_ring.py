"""Unit tests for the per-session replay ring (STR-1066, hermes-mobile plugin).

Covers the standalone data structure only (spec
``docs/RESUMABLE-STREAM-PROTOCOL.md`` §2/§3). No server.py wiring is exercised
here — the ring is constructed directly with injected caps.

Groups:
  * three-way cap eviction: frame-count cap, per-session byte cap, aggregate
    (LRU) byte cap;
  * floor advance after eviction and the ``resume_from`` decision for a client
    older than the floor;
  * lazy creation and orphan-reap / drop.
"""

import json

import pytest


def _frame(nbytes: int, tag: str = "x") -> str:
    """A frame_json string of exactly ``nbytes`` UTF-8 bytes (ASCII payload)."""
    return tag[0] * nbytes


# ---------------------------------------------------------------------------
# Lazy creation (spec §2.4)
# ---------------------------------------------------------------------------

def test_lazy_create_on_first_append(replay_ring):
    mgr = replay_ring.ReplayRingManager()
    assert not mgr.has_ring("s1")
    assert mgr.frame_count("s1") == 0
    assert mgr.floor("s1") is None
    assert mgr.head("s1") is None
    assert mgr.session_count() == 0

    mgr.append("s1", 1, _frame(10))

    assert mgr.has_ring("s1")
    assert mgr.frame_count("s1") == 1
    assert mgr.floor("s1") == 1
    assert mgr.head("s1") == 1
    assert mgr.session_count() == 1


def test_append_accepts_dict_and_bytes_frames(replay_ring):
    mgr = replay_ring.ReplayRingManager()
    mgr.append("s1", 1, {"type": "message.delta", "seq": 1})
    mgr.append("s1", 2, b'{"type":"tool.start"}')
    # Dict normalized to JSON; both accounted in bytes.
    d = mgr.decide("s1", 0)
    assert d.is_replay
    assert json.loads(d.frames[0]) == {"type": "message.delta", "seq": 1}
    assert d.frames[1] == '{"type":"tool.start"}'
    assert mgr.session_bytes("s1") > 0


# ---------------------------------------------------------------------------
# Cap 1 — per-session frame-count eviction + floor advance (spec §2.2/§2.3)
# ---------------------------------------------------------------------------

def test_frame_count_cap_evicts_oldest_and_advances_floor(replay_ring):
    cfg = replay_ring.ReplayRingConfig(frames=3, session_bytes=10_000, total_bytes=10_000)
    mgr = replay_ring.ReplayRingManager(cfg)
    for seq in range(1, 6):  # 1..5
        mgr.append("s1", seq, _frame(10))

    # Only the newest 3 frames survive: seq 3,4,5.
    assert mgr.frame_count("s1") == 3
    assert mgr.floor("s1") == 3      # evicting seq=2 advanced floor to 3
    assert mgr.head("s1") == 5       # head tracks highest ever appended


# ---------------------------------------------------------------------------
# Cap 2 — per-session byte eviction (spec §2.2)
# ---------------------------------------------------------------------------

def test_byte_cap_evicts_oldest(replay_ring):
    # 100-byte frames, 250-byte cap => at most 2 frames retained.
    cfg = replay_ring.ReplayRingConfig(frames=1000, session_bytes=250, total_bytes=1_000_000)
    mgr = replay_ring.ReplayRingManager(cfg)
    for seq in range(1, 6):  # 1..5, 500 bytes total offered
        mgr.append("s1", seq, _frame(100))

    assert mgr.frame_count("s1") == 2       # 2 * 100 = 200 <= 250; a 3rd would be 300
    assert mgr.session_bytes("s1") == 200
    assert mgr.head("s1") == 5
    assert mgr.floor("s1") == 4             # seq 4,5 retained


def test_single_frame_larger_than_byte_cap_is_retained_alone(replay_ring):
    cfg = replay_ring.ReplayRingConfig(frames=1000, session_bytes=50, total_bytes=1_000_000)
    mgr = replay_ring.ReplayRingManager(cfg)
    mgr.append("s1", 1, _frame(10))
    mgr.append("s1", 2, _frame(200))  # alone exceeds the 50-byte cap

    # Newest frame is never evicted, even over-cap; older one is dropped.
    assert mgr.frame_count("s1") == 1
    assert mgr.head("s1") == 2
    assert mgr.floor("s1") == 2
    assert mgr.session_bytes("s1") == 200


# ---------------------------------------------------------------------------
# Cap 3 — aggregate LRU drop of oldest sessions (spec §2.2)
# ---------------------------------------------------------------------------

def test_aggregate_cap_drops_oldest_session_lru(replay_ring):
    # Per-session caps generous; aggregate cap forces a whole-session drop.
    cfg = replay_ring.ReplayRingConfig(frames=1000, session_bytes=1_000_000, total_bytes=250)
    mgr = replay_ring.ReplayRingManager(cfg)

    mgr.append("old", 1, _frame(100))
    mgr.append("old", 2, _frame(100))   # "old" = 200 bytes, aggregate 200
    mgr.append("new", 1, _frame(100))   # aggregate 300 > 250 -> drop LRU ("old")

    assert not mgr.has_ring("old")      # oldest session dropped whole
    assert mgr.has_ring("new")
    assert mgr.aggregate_bytes() == 100
    assert mgr.session_count() == 1


def test_aggregate_drop_makes_session_a_fallback_candidate(replay_ring):
    cfg = replay_ring.ReplayRingConfig(frames=1000, session_bytes=1_000_000, total_bytes=250)
    mgr = replay_ring.ReplayRingManager(cfg)
    mgr.append("old", 1, _frame(100))
    mgr.append("old", 2, _frame(100))
    mgr.append("new", 1, _frame(100))   # evicts "old"

    # A resume against the dropped session is the sanctioned full refetch.
    d = mgr.decide("old", 1)
    assert d.is_fallback
    assert d.count == -1


def test_resume_activity_refreshes_lru_position(replay_ring):
    # A session that is actively resuming must not be the LRU victim.
    cfg = replay_ring.ReplayRingConfig(frames=1000, session_bytes=1_000_000, total_bytes=250)
    mgr = replay_ring.ReplayRingManager(cfg)
    mgr.append("a", 1, _frame(100))
    mgr.append("b", 1, _frame(100))     # a older than b (aggregate 200, under cap)

    mgr.decide("a", 0)                  # touch "a" -> now newer than "b"

    mgr.append("c", 1, _frame(100))     # aggregate 300 > 250 -> drop LRU
    assert not mgr.has_ring("b")        # "b" is now the oldest, not "a"
    assert mgr.has_ring("a")
    assert mgr.has_ring("c")


# ---------------------------------------------------------------------------
# Floor advance + resume decision matrix (spec §3.2)
# ---------------------------------------------------------------------------

def test_resume_decision_matrix_and_older_than_floor(replay_ring):
    cfg = replay_ring.ReplayRingConfig(frames=3, session_bytes=10_000, total_bytes=10_000)
    mgr = replay_ring.ReplayRingManager(cfg)
    for seq in range(1, 6):  # keeps seq 3,4,5; floor=3, head=5
        mgr.append("s1", seq, _frame(10, tag=str(seq)))
    assert (mgr.floor("s1"), mgr.head("s1")) == (3, 5)

    # Case 1: R >= head -> current, nothing to replay.
    cur = mgr.decide("s1", 5)
    assert cur.is_current and cur.count == 0 and cur.frames == []
    ahead = mgr.decide("s1", 9)
    assert ahead.is_current and ahead.count == 0

    # Case 2: floor <= R+1 <= head -> replay the contiguous tail.
    rep = mgr.decide("s1", 2)          # nxt=3 == floor
    assert rep.is_replay
    assert (rep.from_seq, rep.to_seq, rep.count) == (3, 5, 3)
    assert len(rep.frames) == 3        # seq 3,4,5

    rep2 = mgr.decide("s1", 4)         # nxt=5
    assert rep2.is_replay
    assert (rep2.from_seq, rep2.to_seq, rep2.count) == (5, 5, 1)
    assert len(rep2.frames) == 1

    # Case 3: R+1 < floor -> older than the evicted floor -> full refetch.
    fb = mgr.decide("s1", 1)           # nxt=2 < floor 3
    assert fb.is_fallback
    assert (fb.from_seq, fb.to_seq, fb.count) == (2, 5, -1)


def test_replay_frames_are_original_and_ordered(replay_ring):
    mgr = replay_ring.ReplayRingManager()
    frames = {seq: f'{{"seq":{seq}}}' for seq in range(1, 5)}
    for seq, f in frames.items():
        mgr.append("s1", seq, f)

    d = mgr.decide("s1", 1)            # replay 2,3,4
    assert d.is_replay
    assert d.frames == [frames[2], frames[3], frames[4]]


def test_resume_with_no_ring_is_fallback(replay_ring):
    mgr = replay_ring.ReplayRingManager()
    d = mgr.decide("never-seen", 7)
    assert d.is_fallback
    assert d.count == -1


# ---------------------------------------------------------------------------
# Orphan-reap / drop (spec §2.4)
# ---------------------------------------------------------------------------

def test_drop_removes_ring_and_reclaims_bytes(replay_ring):
    mgr = replay_ring.ReplayRingManager()
    mgr.append("s1", 1, _frame(100))
    assert mgr.has_ring("s1")
    assert mgr.aggregate_bytes() == 100

    assert mgr.drop("s1") is True
    assert not mgr.has_ring("s1")
    assert mgr.aggregate_bytes() == 0
    # Idempotent: dropping again is a no-op.
    assert mgr.drop("s1") is False


def test_drop_then_resume_is_fallback(replay_ring):
    mgr = replay_ring.ReplayRingManager()
    mgr.append("s1", 1, _frame(10))
    mgr.append("s1", 2, _frame(10))
    mgr.drop("s1")                     # orphan-reap
    assert mgr.decide("s1", 1).is_fallback


def test_reap_orphans_keeps_active_drops_the_rest(replay_ring):
    mgr = replay_ring.ReplayRingManager()
    for key in ("a", "b", "c"):
        mgr.append(key, 1, _frame(10))

    dropped = mgr.reap_orphans({"a"})  # only "a" has a live transport
    assert set(dropped) == {"b", "c"}
    assert mgr.has_ring("a")
    assert not mgr.has_ring("b")
    assert not mgr.has_ring("c")
    assert mgr.aggregate_bytes() == 10


# ---------------------------------------------------------------------------
# Config: injectable, defaulted to spec, validated
# ---------------------------------------------------------------------------

def test_config_defaults_match_spec(replay_ring):
    cfg = replay_ring.ReplayRingConfig()
    assert cfg.frames == 512
    assert cfg.session_bytes == 4 * 1024 * 1024
    assert cfg.total_bytes == 128 * 1024 * 1024
    # Manager without explicit config uses the spec defaults.
    assert replay_ring.ReplayRingManager().config.frames == 512


@pytest.mark.parametrize("kwargs", [
    {"frames": 0},
    {"session_bytes": 0},
    {"total_bytes": 0},
    {"frames": -1},
])
def test_config_rejects_nonpositive_caps(replay_ring, kwargs):
    with pytest.raises(ValueError):
        replay_ring.ReplayRingConfig(**kwargs)


# ---------------------------------------------------------------------------
# Module-level default manager (thin fenced-parent call surface)
# ---------------------------------------------------------------------------

def test_default_manager_is_singleton_and_resettable(replay_ring):
    replay_ring.reset_default()
    m1 = replay_ring.get_default()
    m2 = replay_ring.get_default()
    assert m1 is m2
    replay_ring.reset_default()
    assert replay_ring.get_default() is not m1
    replay_ring.reset_default()
