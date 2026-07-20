"""Scenario (d) — taskList lifecycle (A5).

The ``todo`` tool is the one tool the reframer does NOT collapse into a generic
``toolCall``: it carries the agent's persistent task list. The relay drives a
SINGLE ``taskList`` item on a stable id (``<sid>:tasks``) through the
started → delta → completed lifecycle (RELAY-PHONE-PROTOCOL.md §2).

This test asserts:

* a ``taskList`` item appears (item.started) with the partial list;
* a follow-on item.delta carries the in-progress REPLACE patch (full list, not
  append — the protocol's "completed-is-authoritative" rule for tasks);
* a final item.completed with every task completed (`all_complete` true);
* the item_id is stable (the same ``<sid>:tasks`` across all three frames).
"""

from __future__ import annotations

import pytest

pytestmark = pytest.mark.asyncio


async def test_tasklist_lifecycle(mock_gateway, phone_factory, evidence):
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(mock_gateway, script="tasklist")
    phone = await phone_factory()

    res = await phone.submit(text="Plan the work", session_id=sid)
    driven_sid = res["result"]["session_id"]

    # Wait for the taskList item to be started (first tool.start with name=todo).
    started = await phone.wait_for(
        "item.started", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "taskList",
    )
    stable_id = started.body.get("item_id")
    assert stable_id == f"{driven_sid}:tasks", (
        f"taskList item_id is not the stable <sid>:tasks: {stable_id!r}"
    )

    # An item.delta REPLACE — the in-progress full list (NOT an append).
    delta = await phone.wait_for(
        "item.delta", sid=driven_sid, timeout=10.0,
        predicate=lambda f: f.body.get("item_id") == stable_id,
    )
    patch = phone.delta_patch(delta)
    assert "tasks" in patch, (
        f"taskList delta missing full-list tasks patch: {patch!r}"
    )
    mid_tasks = patch["tasks"]
    mid_statuses = {t["id"]: t["status"] for t in mid_tasks}
    # The mid-list has t1 completed, t2 in_progress — NOT all done.
    assert mid_statuses["t1"] == "completed", mid_statuses
    assert mid_statuses["t2"] == "in_progress", mid_statuses

    # The final item.completed — all tasks done.
    completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: (
            phone.item_type(f) == "taskList"
            and f.body.get("item_id") == stable_id
        ),
    )
    final_body = phone.item_body(completed)
    final_tasks = final_body.get("tasks", [])
    final_statuses = {t["id"]: t["status"] for t in final_tasks}
    assert all(s in ("completed", "cancelled") for s in final_statuses.values()), (
        f"not all tasks done: {final_statuses}"
    )
    counts = final_body.get("counts", {})
    assert counts.get("completed") + counts.get("cancelled", 0) == counts.get("total"), (
        f"counts do not reflect all-complete: {counts}"
    )

    # The stable id held across all three frames (no per-call churn).
    assert started.body["item_id"] == delta.body["item_id"] == completed.body["item_id"]

    # Ordering: started -> delta -> completed.
    assert started.seq < delta.seq < completed.seq

    evidence("d-tasklist-lifecycle", {
        "session_id": driven_sid,
        "stable_item_id": stable_id,
        "mid_statuses": mid_statuses,
        "final_statuses": final_statuses,
        "counts": counts,
        "started_seq": started.seq,
        "delta_seq": delta.seq,
        "completed_seq": completed.seq,
    })
