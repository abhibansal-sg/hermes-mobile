"""hermes-mobile plugin — transcript delta-sync logic (pure, testable).

The iOS app keeps an on-device SQLite mirror of each session's transcript plus a
per-session cursor (``after_id`` = the max DB message id it has cached, and
``prefix_count`` = how many active rows it holds at-or-before that id). Today it
refetches the FULL transcript on every change. This module decides, purely from
the server's current active message list + the client's cursor, whether a SAFE
incremental delta can be served.

WHY A GENERATION GUARD IS NEEDED
--------------------------------
A naive ``WHERE id > after_id`` is unsafe because Hermes rewrites history in ways
that shift/replace message ids:
  * ``replace_messages`` (retry / edit / ACP turn-end) does DELETE + re-INSERT →
    every row gets a NEW autoincrement id; the client's cached ids are stale.
  * ``_compress_context`` rotates to a NEW session_id with fresh rows.
  * ``rewind_to_message`` soft-deletes a suffix (``active=0``).
After any of these, appending ``WHERE id > after_id`` rows onto the client's stale
cache would duplicate or mis-order the transcript.

THE SAFE CHECK (read-only, no schema change, no hooks)
------------------------------------------------------
A delta is safe IFF the client's cached prefix is provably unchanged:
  1. the cursor row (``after_id``) is STILL present and active, AND
  2. the count of active rows with ``id <= after_id`` equals the client's
     ``prefix_count``.
Pure append always passes both (cursor still there, prefix count unchanged). Any
prefix reshape fails (1) — the cursor row was deleted/reinserted — or (2) — the
prefix row count changed. On failure the client is told to FULL-RESYNC. This is
derived entirely from the existing DB state; it needs no stock-schema column and
no gateway hooks.
"""

from __future__ import annotations

from typing import Any, Dict, List, Tuple


def decide_delta(
    messages: List[Dict[str, Any]],
    after_id: int,
    prefix_count: int,
) -> Tuple[bool, List[Dict[str, Any]], int, int]:
    """Decide whether a safe delta can be served for the given client cursor.

    Args:
        messages: the session's ACTIVE messages, ordered by ascending ``id``
            (exactly what ``SessionDB.get_messages`` returns).
        after_id: the client's cursor — the max DB id it has cached. ``<= 0`` means
            "no cursor" (cold fetch).
        prefix_count: the number of active rows the client holds with
            ``id <= after_id``. ``< 0`` means "unknown" (cold fetch).

    Returns:
        ``(is_delta, out_messages, total, max_id)`` where ``out_messages`` is the
        tail slice (``id > after_id``) when a delta is safe, else the full list.
        ``total`` is the current active row count, ``max_id`` the current max id —
        the client persists these as its next ``(prefix_count, after_id)``.
    """
    total = len(messages)
    max_id = messages[-1].get("id", 0) if messages else 0

    if after_id and after_id > 0 and prefix_count is not None and prefix_count >= 0:
        cursor_present = any(m.get("id") == after_id for m in messages)
        count_at_or_before = sum(1 for m in messages if m.get("id", 0) <= after_id)
        if cursor_present and count_at_or_before == prefix_count:
            tail = [m for m in messages if m.get("id", 0) > after_id]
            return True, tail, total, max_id

    return False, messages, total, max_id


def shape_messages(
    messages: List[Dict[str, Any]],
    shape: str,
) -> List[Dict[str, Any]]:
    """Tier the payload for a faster cold-open (Phase 4 / scarf skeleton→hydrate).

    Rows are NEVER dropped — only heavy fields are nulled — so the delta cursor's
    ``prefix_count`` (a ROW count) stays stable across shapes. A boolean flag is
    added wherever a field was elided so the client knows to hydrate it later:
      * ``skeleton`` — conversational text only: null ``reasoning_content`` AND
        ``tool_calls`` (the two heavy columns; a 157-row session with 20KB+
        reasoning blobs is what hit the SQLite timeout on the desktop sibling).
      * ``light`` — null ``reasoning_content`` only (keep tool calls).
      * ``full`` (or any unknown value) — returned unchanged.

    Returns NEW row dicts when shaping; the input rows are never mutated.
    """
    if shape not in ("skeleton", "light"):
        return messages
    out: List[Dict[str, Any]] = []
    for m in messages:
        shaped = dict(m)
        if shaped.get("reasoning_content"):
            shaped["has_reasoning_content"] = True
            shaped["reasoning_content"] = None
        if shape == "skeleton" and shaped.get("tool_calls"):
            shaped["has_tool_calls"] = True
            shaped["tool_calls"] = None
        out.append(shaped)
    return out
