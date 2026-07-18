"""The reuse path resolves: plugin_bridge locates + imports the plumbing.

This proves the zero-fork reuse contract — the relay imports the SAME
replay_ring module the gateway plugin ships, not a copy. ``replay_ring`` is
stdlib-only, so it imports cleanly in the hermetic test venv and fully exercises
the bridge. ``push_engine`` / ``device_tokens`` transitively pull the full
hermes dependency tree (yaml, etc.) which is present only in the co-located
gateway venv, NOT this unit-test venv — so here we assert the bridge RESOLVES
their paths without importing them (a live import is an e2e concern).
"""

from __future__ import annotations

from hermes_relay import plugin_bridge


def test_finds_plugin_dir_in_worktree():
    d = plugin_bridge.find_plugin_dir()
    assert d.name == "hermes-mobile"
    assert (d / "replay_ring.py").exists()


def test_imports_replay_ring_and_it_is_usable():
    rr = plugin_bridge.import_replay_ring()
    mgr = rr.ReplayRingManager(rr.ReplayRingConfig(frames=4))
    mgr.append("connA", 1, '{"seq":1}')
    mgr.append("connA", 2, '{"seq":2}')
    decision = mgr.decide("connA", 1)  # resume from seq 1 -> replay [2..head]
    assert decision.is_replay
    assert decision.from_seq == 2
    assert decision.to_seq == 2


def test_resolves_heavier_plumbing_paths_without_importing():
    # push_engine + device_tokens exist next to replay_ring; importing them needs
    # the full gateway venv, so we only assert the bridge points at the real files.
    d = plugin_bridge.find_plugin_dir()
    assert (d / "push_engine.py").exists()
    assert (d / "device_tokens.py").exists()
    # repo root (for utils/hermes_state) is what ensure_on_path adds alongside.
    assert (plugin_bridge.repo_root() / "utils.py").exists()
