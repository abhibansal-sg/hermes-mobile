"""ABH-462 / R-48 durable ``prompt.submit`` receipt contract."""

from __future__ import annotations

import sqlite3
import threading
import uuid

import pytest

from hermes_state import SessionDB
from tests.plugins.hermes_mobile.conftest import load_plugin_module
from tui_gateway import server

_REAL_THREAD = threading.Thread


def _session(profile_home, **extra):
    return {
        "agent": object(),
        "session_key": "stored-session",
        "history": [],
        "history_lock": threading.Lock(),
        "history_version": 0,
        "running": False,
        "transport": None,
        "attached_images": [],
        "profile_home": str(profile_home),
        **extra,
    }


@pytest.fixture
def receipts():
    return load_plugin_module("prompt_receipts")


@pytest.fixture
def isolated_gateway(monkeypatch):
    """Make prompt acceptance deterministic without running an agent thread."""
    starts = []

    class _Thread:
        def __init__(self, *args, target=None, **kwargs):
            self.target = target

        def start(self):
            starts.append(self.target)

    monkeypatch.setattr(server, "_start_agent_build", lambda *a, **k: None)
    monkeypatch.setattr(server, "_ensure_session_db_row", lambda *a, **k: None)
    monkeypatch.setattr(server, "_persist_turn_start", lambda *a, **k: None)
    monkeypatch.setattr(server, "_persist_branch_seed", lambda *a, **k: None)
    monkeypatch.setattr(server.threading, "Thread", _Thread)
    monkeypatch.setattr(server, "current_transport", lambda: None)
    return starts


def _params(message_id, **overrides):
    params = {
        "session_id": "runtime-sid",
        "text": "hello",
        "client_message_id": str(message_id),
    }
    params.update(overrides)
    return params


def test_replay_returns_original_disposition_without_second_execution(
    tmp_path, monkeypatch, receipts, isolated_gateway
):
    provider = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    monkeypatch.setattr(server, "PROMPT_RECEIPT_PROVIDERS", [provider])
    session = _session(tmp_path)
    server._sessions["runtime-sid"] = session
    message_id = uuid.uuid4()
    try:
        first = server._methods["prompt.submit"]("r1", _params(message_id))
        assert first["result"]["turn_id"].startswith("turn_")
        assert first["result"] == {
            "status": "streaming",
            "turn_id": first["result"]["turn_id"],
            "accepted": True,
            "client_message_id": str(message_id),
            "deduplicated": False,
        }
        assert len(isolated_gateway) == 1

        # Simulate the accepted turn having gone idle, then a gateway restart
        # (new process owner) before the client reconnects and retries.
        session["running"] = False
        session["inflight_turn"] = None
        restarted = receipts.SQLitePromptReceiptProvider(owner_id="process-b")
        monkeypatch.setattr(server, "PROMPT_RECEIPT_PROVIDERS", [restarted])
        second = server._methods["prompt.submit"]("r2", _params(message_id))
        assert second["result"] == {
            **first["result"],
            "deduplicated": True,
        }
        assert len(isolated_gateway) == 1
        assert session["history"] == []
        assert session.get("queued_prompt") is None

        path = provider.database_path(tmp_path)
        with sqlite3.connect(path) as conn:
            assert conn.execute("SELECT count(*) FROM prompt_receipts").fetchone()[0] == 1
    finally:
        server._sessions.pop("runtime-sid", None)


def test_receipt_and_sessiondb_bind_same_authoritative_turn_id(
    tmp_path, monkeypatch, receipts, isolated_gateway
):
    provider = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    monkeypatch.setattr(server, "PROMPT_RECEIPT_PROVIDERS", [provider])
    state_db = SessionDB(db_path=tmp_path / "state.db")
    state_db.create_session("stored-session", source="tui")
    monkeypatch.setattr(server, "_get_db", lambda: state_db)
    # Exercise the real ledger method; only the lazy row creator remains a no-op
    # because the authoritative row was created explicitly above.
    monkeypatch.setattr(
        server,
        "_persist_turn_start",
        lambda session, turn, state="running": state_db.start_turn(
            session["session_key"],
            turn["turn_id"],
            content=turn["user"],
            client_message_id=turn["client_message_id"],
            input_kind=turn["input_kind"],
            accepted_at=turn["started_at"],
            state=state,
            input_id=turn["input_id"],
        ),
    )
    session = _session(tmp_path)
    server._sessions["runtime-sid"] = session
    message_id = uuid.uuid4()
    try:
        first = server._methods["prompt.submit"]("r1", _params(message_id))
        turn_id = first["result"]["turn_id"]
        assert state_db.get_turns("stored-session")[0]["turn_id"] == turn_id
        assert state_db.get_turn_inputs("stored-session", turn_id)[0][
            "client_message_id"
        ] == str(message_id)

        session["running"] = False
        session["inflight_turn"] = None
        replay = server._methods["prompt.submit"]("r2", _params(message_id))
        assert replay["result"]["turn_id"] == turn_id
        assert replay["result"]["deduplicated"] is True
        assert len(state_db.get_turns("stored-session")) == 1
    finally:
        server._sessions.pop("runtime-sid", None)
        state_db.close()


def test_prompt_receipt_fingerprints_and_atomically_associates_stable_assets(
    tmp_path, monkeypatch, receipts, isolated_gateway
):
    provider = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    provider.register_asset(
        profile_home=tmp_path,
        asset_id="asset_0123456789abcdef",
        content_version="sha256:abc",
        path=str(tmp_path / "asset.jpg"),
        media_type="image/jpeg",
        byte_count=3,
        owner_device_id="device-a",
    )
    monkeypatch.setattr(server, "PROMPT_RECEIPT_PROVIDERS", [provider])
    server._sessions["runtime-sid"] = _session(tmp_path)
    message_id = uuid.uuid4()
    reference = {
        "asset_id": "asset_0123456789abcdef",
        "content_version": "sha256:abc",
        "role": "input",
    }
    try:
        response = server._methods["prompt.submit"](
            "r1", _params(message_id, asset_references=[reference])
        )
        assert response["result"]["accepted"] is True
        turn_id = response["result"]["turn_id"]
        with sqlite3.connect(provider.database_path(tmp_path)) as conn:
            association = conn.execute(
                "SELECT operation_id, asset_id, content_version, session_id, "
                "turn_id, role FROM stable_asset_associations"
            ).fetchone()
        assert association == (
            str(message_id),
            reference["asset_id"],
            reference["content_version"],
            "stored-session",
            turn_id,
            "input",
        )

        server._sessions["runtime-sid"]["running"] = False
        server._sessions["runtime-sid"]["inflight_turn"] = None
        conflict = server._methods["prompt.submit"](
            "r2",
            _params(
                message_id,
                asset_references=[{**reference, "content_version": "sha256:changed"}],
            ),
        )
        assert conflict["error"]["code"] == 4091
    finally:
        server._sessions.pop("runtime-sid", None)


@pytest.mark.parametrize(
    "change",
    [
        {"session_id": "different-session"},
        {"text": "different text"},
        {"truncate_before_user_ordinal": 0},
    ],
)
def test_same_id_with_changed_request_returns_4091(
    tmp_path, monkeypatch, receipts, isolated_gateway, change
):
    provider = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    monkeypatch.setattr(server, "PROMPT_RECEIPT_PROVIDERS", [provider])
    # Both requests belong to the same gateway profile even when the conflict
    # deliberately changes the runtime session id to one that is not live.
    monkeypatch.setattr(server, "_prompt_receipt_home", lambda _params: tmp_path)
    server._sessions["runtime-sid"] = _session(tmp_path)
    message_id = uuid.uuid4()
    try:
        assert "result" in server._methods["prompt.submit"]("r1", _params(message_id))
        response = server._methods["prompt.submit"](
            "r2", _params(message_id, **change)
        )
        assert response["error"]["code"] == 4091
        assert len(isolated_gateway) == 1
    finally:
        server._sessions.pop("runtime-sid", None)


def test_concurrent_identical_requests_execute_once_and_report_in_progress(
    tmp_path, monkeypatch, receipts, isolated_gateway
):
    provider = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    real_complete = provider.complete
    completion_entered = threading.Event()
    allow_completion = threading.Event()

    def blocking_complete(reservation, disposition):
        completion_entered.set()
        assert allow_completion.wait(timeout=5)
        real_complete(reservation, disposition)

    monkeypatch.setattr(provider, "complete", blocking_complete)
    monkeypatch.setattr(server, "PROMPT_RECEIPT_PROVIDERS", [provider])
    server._sessions["runtime-sid"] = _session(tmp_path)
    message_id = uuid.uuid4()
    responses = {}

    def submit(name):
        responses[name] = server._methods["prompt.submit"](name, _params(message_id))

    first = _REAL_THREAD(target=submit, args=("first",))
    try:
        first.start()
        assert completion_entered.wait(timeout=5)
        submit("second")
        assert responses["second"]["result"]["status"] == "in_progress"
        assert responses["second"]["result"]["accepted"] is False
        allow_completion.set()
        first.join(timeout=5)
        assert not first.is_alive()
        assert responses["first"]["result"]["status"] == "streaming"
        assert responses["first"]["result"]["accepted"] is True
        assert len(isolated_gateway) == 1

        with sqlite3.connect(provider.database_path(tmp_path)) as conn:
            row = conn.execute(
                "SELECT state, count(*) FROM prompt_receipts"
            ).fetchone()
        assert row == ("accepted", 1)
    finally:
        allow_completion.set()
        first.join(timeout=5)
        server._sessions.pop("runtime-sid", None)


def test_abandoned_reservation_is_indeterminate_after_restart(tmp_path, receipts):
    message_id = str(uuid.uuid4())
    first_process = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    request = dict(
        profile_home=tmp_path,
        client_message_id=message_id,
        session_id="runtime-sid",
        text="hello",
        truncate_before_user_ordinal=None,
    )
    assert first_process.reserve(**request)["state"] == "claimed"
    assert first_process.reserve(**request)["state"] == "in_progress"

    restarted = receipts.SQLitePromptReceiptProvider(owner_id="process-b")
    assert restarted.reserve(**request)["state"] == "indeterminate"
    assert restarted.reserve(**request)["state"] == "indeterminate"


def test_indeterminate_asset_reservation_remains_a_gc_root(tmp_path, receipts):
    asset_path = tmp_path / "asset.jpg"
    asset_path.write_bytes(b"abc")
    first = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    first.register_asset(
        profile_home=tmp_path,
        asset_id="asset_pending",
        content_version="sha256:abc",
        path=str(asset_path),
        media_type="image/jpeg",
        byte_count=3,
        owner_device_id=None,
    )
    request = dict(
        profile_home=tmp_path,
        client_message_id=str(uuid.uuid4()),
        session_id="runtime-sid",
        text="hello",
        truncate_before_user_ordinal=None,
        asset_references=[
            {
                "asset_id": "asset_pending",
                "content_version": "sha256:abc",
                "role": "input",
            }
        ],
    )
    assert first.reserve(**request)["state"] == "claimed"
    restarted = receipts.SQLitePromptReceiptProvider(owner_id="process-b")
    assert restarted.reserve(**request)["state"] == "indeterminate"
    assert restarted.is_referenced_path(
        profile_home=tmp_path, path=str(asset_path)
    )
    assert not restarted.mark_unreferenced_asset_deleted(
        profile_home=tmp_path, path=str(asset_path)
    )


def test_receipts_are_profile_home_isolated(tmp_path, receipts):
    provider = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    message_id = str(uuid.uuid4())
    common = dict(
        client_message_id=message_id,
        session_id="runtime-sid",
        truncate_before_user_ordinal=None,
    )
    home_a = tmp_path / "profile-a"
    home_b = tmp_path / "profile-b"
    assert provider.reserve(profile_home=home_a, text="alpha", **common)["state"] == "claimed"
    assert provider.reserve(profile_home=home_b, text="beta", **common)["state"] == "claimed"
    assert provider.database_path(home_a).exists()
    assert provider.database_path(home_b).exists()


def test_receipts_prune_only_after_thirty_days(tmp_path, receipts):
    now = [1_000_000.0]
    provider = receipts.SQLitePromptReceiptProvider(
        owner_id="process-a", clock=lambda: now[0]
    )
    message_id = str(uuid.uuid4())
    request = dict(
        profile_home=tmp_path,
        client_message_id=message_id,
        session_id="runtime-sid",
        text="hello",
        truncate_before_user_ordinal=None,
    )
    claim = provider.reserve(**request)
    provider.complete(claim["reservation"], {"status": "streaming"})

    now[0] += receipts.RETENTION_SECONDS
    assert provider.reserve(**request)["state"] == "replay"

    now[0] += 0.001
    changed = dict(request, text="new prompt after retention")
    assert provider.reserve(**changed)["state"] == "claimed"


def test_plugin_disabled_client_id_has_zero_behavior_change(
    tmp_path, monkeypatch, isolated_gateway
):
    monkeypatch.setattr(server, "PROMPT_RECEIPT_PROVIDERS", [])
    monkeypatch.setattr("hermes_cli.plugins.discover_plugins", lambda: None)
    invalid_id = "not-even-a-uuid"

    server._sessions["runtime-sid"] = _session(tmp_path)
    try:
        with_id = server._methods["prompt.submit"](
            "same-rid", _params(invalid_id)
        )
    finally:
        server._sessions.pop("runtime-sid", None)

    server._sessions["runtime-sid"] = _session(tmp_path)
    try:
        without_id = server._methods["prompt.submit"](
            "same-rid", {"session_id": "runtime-sid", "text": "hello"}
        )
        assert with_id == without_id == {
            "jsonrpc": "2.0",
            "id": "same-rid",
            "result": {"status": "streaming"},
        }
    finally:
        server._sessions.pop("runtime-sid", None)


def test_first_id_enabled_send_discovers_provider_before_handler_mutation(
    monkeypatch,
):
    class _Provider:
        provider_name = "test.lazy-discovery"

        def reserve(self, **kwargs):
            return {"state": "conflict"}

    provider = _Provider()
    monkeypatch.setattr(server, "PROMPT_RECEIPT_PROVIDERS", [])
    monkeypatch.setattr(
        "hermes_cli.plugins.discover_plugins",
        lambda: server.register_prompt_receipt_provider(provider),
    )
    response = server._methods["prompt.submit"](
        "lazy-rid", _params(uuid.uuid4())
    )
    assert response["error"]["code"] == 4091
    assert server.PROMPT_RECEIPT_PROVIDERS == [provider]


def test_plugin_register_wires_receipt_provider_idempotently(monkeypatch, receipts):
    plugin = load_plugin_module("prompt_receipts").__package__
    plugin_module = __import__(plugin, fromlist=["register"])
    monkeypatch.setattr(server, "PROMPT_RECEIPT_PROVIDERS", [])
    plugin_module._wire_prompt_receipts()
    plugin_module._wire_prompt_receipts()
    server.register_prompt_receipt_provider(
        receipts.SQLitePromptReceiptProvider(owner_id="reloaded-plugin")
    )
    assert server.PROMPT_RECEIPT_PROVIDERS == [receipts.PROVIDER]
