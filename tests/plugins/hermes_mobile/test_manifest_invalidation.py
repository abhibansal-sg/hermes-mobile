from __future__ import annotations

import json

from .conftest import load_plugin_module


def test_frozen_payload_is_data_free(push_engine):
    payload = push_engine.build_manifest_invalidation_payload("all", 1843, "attention")
    assert payload == {
        "aps": {"content-available": 1},
        "sync": {"scope": "all", "revision": 1843, "reason": "attention"},
    }
    assert json.dumps(payload, separators=(",", ":")) == (
        '{"aps":{"content-available":1},"sync":{"scope":"all",'
        '"revision":1843,"reason":"attention"}}'
    )
    assert not ({"alert", "badge", "sound"} & payload["aps"].keys())


def test_scope_coalescing_high_water_and_restart(tmp_path):
    mod = load_plugin_module("manifest_invalidation")
    sent = []
    path = tmp_path / "journal.json"
    publisher = mod.InvalidationPublisher(path, lambda *args: sent.append(args), 60)
    assert publisher.invalidate("all", "sessions") == 1
    assert publisher.invalidate("all", "attention") == 2
    assert publisher.invalidate("profile:work", "widget") == 3
    publisher.flush()
    assert sent == [("all", 2, "coalesced"), ("profile:work", 3, "widget")]
    assert mod.InvalidationPublisher(path).revision("all") == 2
    assert mod.InvalidationPublisher(path).revision("profile:work") == 3
    assert json.loads(path.read_text())["high_water"] == 3


def test_revision_is_durable_before_sender(tmp_path):
    mod = load_plugin_module("manifest_invalidation")
    path = tmp_path / "journal.json"
    observed = []
    publisher = mod.InvalidationPublisher(
        path, lambda _s, revision, _r: observed.append(json.loads(path.read_text())["high_water"] == revision), 60
    )
    publisher.invalidate("all", "transcript")
    publisher.flush()
    assert observed == [True]


def test_event_reason_mapping_and_no_content_leak(tmp_path, monkeypatch):
    mod = load_plugin_module("manifest_invalidation")
    sent = []
    publisher = mod.InvalidationPublisher(tmp_path / "journal.json", lambda *x: sent.append(x), 60)
    monkeypatch.setattr(mod, "_publisher", publisher)
    cases = {
        "session.deleted": {"sessions", "transcript", "widget"},
        "session.archived": {"sessions", "widget"},
        "approval.request": {"attention", "active_turns", "widget"},
        "prompt.removed": {"attention", "active_turns", "widget"},
        "message.start": {"active_turns", "widget"},
        "transcript.updated": {"transcript", "sessions"},
        "widget.updated": {"widget"},
        "push.registered": {"push_registry"},
    }
    for event, reasons in cases.items():
        start = publisher.revision("all")
        mod.handle_gateway_event(event, "secret-session", {"title": "secret", "prompt": "secret"})
        publisher.flush()
        assert publisher.revision("all") == start + len(reasons)
        assert sent[-1][2] == (next(iter(reasons)) if len(reasons) == 1 else "coalesced")
        assert "secret" not in repr(sent[-1])


def test_relay_preserves_same_payload_and_background_headers(monkeypatch, push_engine):
    relay_client = load_plugin_module("relay_client")
    captured = {}
    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay")
    monkeypatch.setattr(relay_client, "send_manifest_invalidation_background", lambda **kw: captured.update(kw))
    assert push_engine.notify_manifest_invalidation("profile:work", 9, "widget") == 1
    assert captured["payload"] == push_engine.build_manifest_invalidation_payload("profile:work", 9, "widget")
    assert captured["headers"] == {
        "apns-topic": "ai.hermes.app",
        "apns-push-type": "background",
        "apns-priority": "5",
        "apns-expiration": "0",
        "apns-collapse-id": "hermes-sync:profile:work",
    }


def test_push_failure_does_not_undo_durable_revision(tmp_path):
    mod = load_plugin_module("manifest_invalidation")
    path = tmp_path / "journal.json"
    publisher = mod.InvalidationPublisher(path, lambda *_args: (_ for _ in ()).throw(RuntimeError("down")), 60)
    assert publisher.invalidate("all", "sessions") == 1
    publisher.flush()
    assert json.loads(path.read_text())["high_water"] == 1
