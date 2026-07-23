"""The proxy resolves the existing plugin device-token authority."""

from __future__ import annotations

from hermes_relay import plugin_bridge


def test_finds_plugin_dir_in_worktree():
    d = plugin_bridge.find_plugin_dir()
    assert d.name == "hermes-mobile"
    assert (d / "replay_ring.py").exists()


def test_resolves_device_token_authority():
    d = plugin_bridge.find_plugin_dir()
    assert (d / "device_tokens.py").exists()
    assert (plugin_bridge.repo_root() / "utils.py").exists()
