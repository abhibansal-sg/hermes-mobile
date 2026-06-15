"""Unit tests for the transcript delta-sync generation guard
(``plugins/hermes-mobile/transcript_sync.decide_delta``).

The guard must serve a safe incremental delta ONLY when the client's cached
prefix is provably unchanged, and fall back to a full re-sync on every kind of
history reshape (replace_messages, rewind/soft-delete, compaction). These tests
exercise each case against the pure function — no DB, no network.
"""

from __future__ import annotations

from tests.plugins.hermes_mobile.conftest import load_plugin_module

transcript_sync = load_plugin_module("transcript_sync")


def _msgs(ids):
    """Build a minimal active message list (ordered by id asc) for the given ids."""
    return [{"id": i, "role": "user", "content": f"m{i}"} for i in ids]


def test_cold_fetch_returns_full():
    msgs = _msgs([1, 2, 3])
    is_delta, out, total, max_id = transcript_sync.decide_delta(msgs, after_id=0, prefix_count=-1)
    assert is_delta is False
    assert out == msgs
    assert total == 3
    assert max_id == 3


def test_empty_session():
    is_delta, out, total, max_id = transcript_sync.decide_delta([], after_id=0, prefix_count=-1)
    assert is_delta is False
    assert out == []
    assert total == 0
    assert max_id == 0


def test_pure_append_returns_only_new_tail():
    # Client cached ids 1..3 (prefix_count=3, after_id=3). Server appended 4,5.
    msgs = _msgs([1, 2, 3, 4, 5])
    is_delta, out, total, max_id = transcript_sync.decide_delta(msgs, after_id=3, prefix_count=3)
    assert is_delta is True
    assert [m["id"] for m in out] == [4, 5]
    assert total == 5
    assert max_id == 5


def test_no_new_messages_returns_empty_delta():
    # Client is fully caught up: cursor at max, prefix_count == total.
    msgs = _msgs([1, 2, 3])
    is_delta, out, total, max_id = transcript_sync.decide_delta(msgs, after_id=3, prefix_count=3)
    assert is_delta is True
    assert out == []
    assert total == 3
    assert max_id == 3


def test_replace_messages_forces_full_resync():
    # Client cached ids 1..3. A retry did DELETE+re-INSERT → new ids 10,11,12.
    # The cursor row (3) no longer exists → must full-resync (else duplication).
    msgs = _msgs([10, 11, 12])
    is_delta, out, total, max_id = transcript_sync.decide_delta(msgs, after_id=3, prefix_count=3)
    assert is_delta is False
    assert [m["id"] for m in out] == [10, 11, 12]
    assert total == 3
    assert max_id == 12


def test_rewind_below_cursor_forces_full_resync():
    # Client cached ids 1..5 (prefix_count=5, after_id=5). A rewind soft-deleted
    # ids >=3, so the active set is now 1,2 — the cursor (5) is gone.
    msgs = _msgs([1, 2])
    is_delta, out, total, max_id = transcript_sync.decide_delta(msgs, after_id=5, prefix_count=5)
    assert is_delta is False
    assert [m["id"] for m in out] == [1, 2]


def test_prefix_count_mismatch_forces_full_resync():
    # Cursor row (3) still present, but a mid-prefix row was soft-deleted so the
    # count at-or-before the cursor dropped from 3 to 2 — the prefix reshaped.
    msgs = _msgs([1, 3, 4, 5])  # id 2 removed; 3 still present
    is_delta, out, total, max_id = transcript_sync.decide_delta(msgs, after_id=3, prefix_count=3)
    assert is_delta is False
    assert [m["id"] for m in out] == [1, 3, 4, 5]


def test_negative_prefix_count_is_cold_fetch():
    msgs = _msgs([1, 2, 3])
    is_delta, _out, _total, _max = transcript_sync.decide_delta(msgs, after_id=3, prefix_count=-1)
    assert is_delta is False


# --- shape_messages (Phase 4 skeleton/light tiering) ---

def _heavy(i):
    return {
        "id": i,
        "role": "assistant",
        "content": f"text {i}",
        "reasoning_content": "x" * 5000,
        "tool_calls": [{"id": "t1", "name": "shell"}],
    }


def test_shape_full_is_unchanged():
    msgs = [_heavy(1), _heavy(2)]
    out = transcript_sync.shape_messages(msgs, "full")
    assert out == msgs
    assert out[0]["reasoning_content"] == "x" * 5000


def test_shape_unknown_is_unchanged():
    msgs = [_heavy(1)]
    assert transcript_sync.shape_messages(msgs, "bogus") == msgs


def test_shape_skeleton_nulls_reasoning_and_tools_keeps_rows():
    msgs = [_heavy(1), _heavy(2)]
    out = transcript_sync.shape_messages(msgs, "skeleton")
    assert len(out) == 2  # rows never dropped → prefix_count stays valid
    for row in out:
        assert row["reasoning_content"] is None
        assert row["has_reasoning_content"] is True
        assert row["tool_calls"] is None
        assert row["has_tool_calls"] is True
        assert row["content"].startswith("text")  # text preserved


def test_shape_light_keeps_tool_calls():
    out = transcript_sync.shape_messages([_heavy(1)], "light")
    assert out[0]["reasoning_content"] is None
    assert out[0]["has_reasoning_content"] is True
    assert out[0]["tool_calls"] == [{"id": "t1", "name": "shell"}]  # tools kept
    assert "has_tool_calls" not in out[0]


def test_shape_does_not_mutate_input():
    msgs = [_heavy(1)]
    transcript_sync.shape_messages(msgs, "skeleton")
    assert msgs[0]["reasoning_content"] == "x" * 5000  # original untouched


def test_shape_row_without_heavy_fields_unflagged():
    msgs = [{"id": 1, "role": "user", "content": "hi"}]
    out = transcript_sync.shape_messages(msgs, "skeleton")
    assert "has_reasoning_content" not in out[0]
    assert "has_tool_calls" not in out[0]
