"""Atomic control-card APIs required by Factory recipe cancellation."""

from __future__ import annotations

from pathlib import Path

import pytest

from hermes_cli import kanban_db as kb


@pytest.fixture
def kanban_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    kb.init_db()
    return home


def test_create_blocked_task_is_sticky_and_never_dispatchable(kanban_home: Path) -> None:
    with kb.connect_closing() as conn:
        task_id = kb.create_blocked_task(
            conn,
            title="Await approval",
            assignee="recipe-worker",
            workspace_kind="dir",
            workspace_path="/tmp/recipe-workspace",
            block_kind="needs_input",
            reason="approval is required before the recipe can continue",
        )

        task = kb.get_task(conn, task_id)
        assert task is not None
        assert task.status == "blocked"
        assert task.block_kind == "needs_input"
        blocked_event = kb.list_events(conn, task_id)[-1]
        assert blocked_event.kind == "blocked"
        assert blocked_event.payload == {
            "reason": "approval is required before the recipe can continue",
            "kind": "needs_input",
            "recurrences": 0,
        }

        spawns: list[str] = []
        result = kb.dispatch_once(
            conn,
            spawn_fn=lambda task, *_: spawns.append(task.id) or 12345,
        )
        assert task_id not in result.spawned
        assert spawns == []
        assert kb.get_task(conn, task_id).status == "blocked"


def test_cancel_subtree_refuses_when_any_selected_task_has_a_live_worker(
    kanban_home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    with kb.connect_closing() as conn:
        task_id = kb.create_task(conn, title="Still running", assignee="worker")
        with kb.write_txn(conn):
            conn.execute("UPDATE tasks SET worker_pid = ? WHERE id = ?", (4242, task_id))
        monkeypatch.setattr(kb, "_pid_alive", lambda pid: pid == 4242)

        result = kb.cancel_subtree(conn, [task_id])

        assert result == {
            "archived": [],
            "kept": [],
            "refused": f"task {task_id} has a live worker (pid 4242)",
        }
        assert kb.get_task(conn, task_id).status == "ready"


def test_cancel_subtree_archives_children_before_parents(kanban_home: Path) -> None:
    with kb.connect_closing() as conn:
        parent = kb.create_task(conn, title="parent", assignee="worker")
        child = kb.create_task(conn, title="child", assignee="worker", parents=[parent])
        grandchild = kb.create_task(
            conn, title="grandchild", assignee="worker", parents=[child]
        )

        result = kb.cancel_subtree(conn, [parent, child, grandchild])

        assert result["refused"] is None
        assert result["archived"] == [grandchild, child, parent]
        archived_events = conn.execute(
            "SELECT task_id FROM task_events WHERE kind = 'archived' ORDER BY id"
        ).fetchall()
        assert [row["task_id"] for row in archived_events] == [
            grandchild,
            child,
            parent,
        ]


def test_cancel_subtree_keeps_control_card_as_unassigned_needs_input_block(
    kanban_home: Path,
) -> None:
    with kb.connect_closing() as conn:
        work = kb.create_task(conn, title="work", assignee="worker")
        collector = kb.create_task(conn, title="collector", assignee="owner")

        result = kb.cancel_subtree(conn, [work, collector], keep_blocked=[collector])

        assert result == {"archived": [work], "kept": [collector], "refused": None}
        assert kb.get_task(conn, work).status == "archived"
        kept = kb.get_task(conn, collector)
        assert kept.status == "blocked"
        assert kept.assignee is None
        assert kept.block_kind == "needs_input"
        assert kb.list_events(conn, collector)[-1].payload == {
            "reason": "recipe_cancelled",
            "kind": "needs_input",
        }


def test_cancel_subtree_recomputes_only_after_every_parent_is_archived(
    kanban_home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    with kb.connect_closing() as conn:
        first_parent = kb.create_task(conn, title="first", assignee="worker")
        second_parent = kb.create_task(conn, title="second", assignee="worker")
        downstream = kb.create_task(
            conn,
            title="downstream",
            assignee="worker",
            parents=[first_parent, second_parent],
        )
        assert kb.get_task(conn, downstream).status == "todo"

        real_recompute = kb.recompute_ready
        recompute_calls = 0

        def recompute_at_end(conn_arg, *args, **kwargs):
            nonlocal recompute_calls
            recompute_calls += 1
            # This is the only recompute. It must see the entire cancellation,
            # never one archived parent and one still-live parent.
            assert kb.get_task(conn_arg, first_parent).status == "archived"
            assert kb.get_task(conn_arg, second_parent).status == "archived"
            return real_recompute(conn_arg, *args, **kwargs)

        monkeypatch.setattr(kb, "recompute_ready", recompute_at_end)
        result = kb.cancel_subtree(conn, [first_parent, second_parent])

        assert result["archived"] == [second_parent, first_parent]
        assert recompute_calls == 1
        assert kb.get_task(conn, downstream).status == "ready"
        promoted = [
            event for event in kb.list_events(conn, downstream)
            if event.kind == "promoted"
        ]
        assert len(promoted) == 1
