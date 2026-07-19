from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import math
import sqlite3

import pytest

from hermes_relay.v2.protocol import MAX_WIRE_INTEGER
from hermes_relay.v2.storage import (
    SCHEMA_VERSION,
    RelayStorage,
    StorageConflict,
    StorageExpired,
    StreamGap,
)


class Clock:
    def __init__(self, value: int = 1_000_000) -> None:
        self.value = value

    def __call__(self) -> int:
        return self.value


class Protector:
    mode = "test-protector"

    def __init__(self) -> None:
        self.protected: list[bytes] = []
        self.deleted: list[bytes] = []

    def protect(self, label: str, secret: bytes) -> bytes:
        wrapped = b"test-v1:" + label.encode() + b":" + secret
        self.protected.append(wrapped)
        return wrapped

    def reveal(self, wrapped: bytes) -> bytes:
        return wrapped.rsplit(b":", 1)[-1]

    def delete(self, wrapped: bytes) -> None:
        self.deleted.append(wrapped)


def test_v15_migration_adds_retirement_and_remote_cleanup_without_losing_v12_data(
    tmp_path,
) -> None:
    path = tmp_path / "relay.sqlite3"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE relay_kem_keys (
            generation INTEGER PRIMARY KEY,
            private_key BLOB NOT NULL,
            public_key BLOB NOT NULL,
            status TEXT NOT NULL,
            not_after_ms INTEGER,
            created_at_ms INTEGER NOT NULL,
            message_count INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO relay_kem_keys VALUES (1,X'01',X'02','previous',500,100,0);
        INSERT INTO relay_kem_keys VALUES (2,X'03',X'04','current',NULL,200,0);

        CREATE TABLE devices (
            device_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            route TEXT NOT NULL UNIQUE,
            status TEXT NOT NULL,
            kem_generation INTEGER NOT NULL,
            kem_public BLOB NOT NULL,
            sign_public BLOB NOT NULL,
            preview_generation INTEGER NOT NULL,
            preview_public BLOB NOT NULL,
            created_at_ms INTEGER NOT NULL,
            confirmed_at_ms INTEGER,
            revoked_at_ms INTEGER
        );
        INSERT INTO devices VALUES
            ('dev_old','Old','rte_old','active',1,zeroblob(32),zeroblob(32),1,
             zeroblob(32),150,150,NULL);
        INSERT INTO devices VALUES
            ('dev_new','New','rte_new','active',1,zeroblob(32),zeroblob(32),1,
             zeroblob(32),250,250,NULL);

        CREATE TABLE push_bindings (
            binding_id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL UNIQUE,
            send_capability BLOB NOT NULL,
            allowed_classes_json BLOB NOT NULL,
            status TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        INSERT INTO push_bindings VALUES
            ('pb_old','dev_old',X'01',X'5B22617070726F76616C225D','active',150,150);

        CREATE TABLE push_binding_exchanges (
            device_id TEXT PRIMARY KEY,
            exchange_id TEXT NOT NULL UNIQUE,
            bind_token BLOB NOT NULL,
            requested_classes_json BLOB NOT NULL,
            state TEXT NOT NULL,
            binding_id TEXT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        INSERT INTO push_binding_exchanges VALUES
            ('dev_old','exg_old',X'746F6B656E',X'5B22757064617465225D',
             'pending',NULL,150,150);

        CREATE TABLE outbox (
            device_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            first_seq INTEGER NOT NULL,
            last_seq INTEGER NOT NULL,
            message_class TEXT NOT NULL,
            envelope_json BLOB NOT NULL,
            state TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            expires_at_ms INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error_code TEXT,
            receipt_kind TEXT NOT NULL DEFAULT 'stream',
            PRIMARY KEY (device_id,message_id)
        );
        INSERT INTO outbox
            (device_id,message_id,first_seq,last_seq,message_class,envelope_json,
             state,created_at_ms,expires_at_ms,receipt_kind)
        VALUES
            ('dev_old','mid_delivery',0,0,'control',X'7B7D','pending',150,400,
             'delivery'),
            ('dev_old','mid_stream',1,1,'state',X'7B7D','pending',150,400,
             'stream');
        PRAGMA user_version=10;
        """
    )
    conn.close()

    store = RelayStorage(tmp_path, clock=lambda: 300)
    old_device = store.get_device("dev_old")
    new_device = store.get_device("dev_new")
    assert old_device.relay_kem_generation == 1
    assert new_device.relay_kem_generation == 2
    assert old_device.re_pair_required is False
    assert old_device.status_reason is None
    assert old_device.hub_revocation_state == "not_required"
    assert old_device.hub_revocation_attempts == 0
    assert old_device.hub_revocation_last_error is None
    assert all(
        key.retirement_started_at_ms is None
        for key in store.relay_kem_keys(include_revoked=True)
    )
    migrated_binding = store._conn.execute(
        "SELECT revoke_attempts,last_error_code FROM push_bindings WHERE device_id='dev_old'"
    ).fetchone()
    assert tuple(migrated_binding) == (0, None)
    migrated_exchange = store._conn.execute(
        """SELECT remote_revoke_state,revoke_attempts,last_error_code
           FROM push_binding_exchanges WHERE device_id='dev_old'"""
    ).fetchone()
    assert tuple(migrated_exchange) == ("not_required", 0, None)
    assert store.outbox_record("dev_old", "mid_delivery").completion_policy == (
        "inner_receipt"
    )
    assert store.outbox_record("dev_old", "mid_stream").completion_policy == (
        "stream_ack"
    )
    assert store._conn.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION


def _device(store: RelayStorage, suffix: str = "1") -> str:
    record = store.register_device(
        device_id=f"dev_{suffix}",
        name=f"Phone {suffix}",
        route=f"rte_device_{suffix}",
        kem_public=bytes([1]) * 32,
        sign_public=bytes([2]) * 32,
        preview_public=bytes([3]) * 32,
    )
    store.activate_device(record.device_id)
    return record.device_id


def test_wal_permissions_identity_and_epoch_survive_restart(tmp_path) -> None:
    state = tmp_path / "profile" / "mobile-relay"
    store = RelayStorage(state)
    original = store.store_identity(
        kem_private=b"k" * 32,
        kem_public=b"K" * 32,
        sign_private=b"s" * 32,
        sign_public=b"S" * 32,
    )
    assert store.journal_mode() == "wal"
    assert state.stat().st_mode & 0o777 == 0o700
    assert store.path.stat().st_mode & 0o777 == 0o600
    for suffix in ("-wal", "-shm"):
        auxiliary = type(store.path)(str(store.path) + suffix)
        if auxiliary.exists():
            assert auxiliary.stat().st_mode & 0o777 == 0o600
    store.close()

    reopened = RelayStorage(state)
    assert reopened.load_identity() == original
    assert reopened.load_identity().relay_epoch == original.relay_epoch


def test_pairing_claim_is_cas_same_device_resumes_other_device_loses(tmp_path) -> None:
    clock = Clock()
    first = RelayStorage(tmp_path, clock=clock)
    offer = first.create_pair_offer(relay_route="rte_agent", ttl_seconds=300)
    second = RelayStorage(tmp_path, clock=clock)

    def claim(store: RelayStorage, key: bytes):
        try:
            return store.claim_pair_offer(offer.offer_id, key).device_key_hash
        except StorageConflict:
            return b"lost"

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(
            executor.map(
                lambda args: claim(*args),
                [(first, b"a" * 32), (second, b"b" * 32)],
            )
        )
    winners = [value for value in results if value != b"lost"]
    assert len(winners) == 1
    assert first.claim_pair_offer(offer.offer_id, winners[0]).state == "claimed"
    first.close()
    second.close()
    assert (
        RelayStorage(tmp_path, clock=clock).get_pair_offer(offer.offer_id).state
        == "claimed"
    )


def test_pairing_transition_expiry_fail_closes_associated_device(tmp_path) -> None:
    clock = Clock()
    store = RelayStorage(tmp_path, clock=clock)
    offer = store.create_pair_offer(relay_route="rte_agent", ttl_seconds=1)
    store.claim_pair_offer(offer.offer_id, b"a" * 32)
    device = store.register_device(
        device_id="dev_expiry_fallback",
        name="Expiry fallback",
        route="rte_expiry_fallback",
        kem_public=b"k" * 32,
        sign_public=b"s" * 32,
        preview_public=b"p" * 32,
    )
    store.associate_pair_offer_device(offer.offer_id, device.device_id)

    clock.value = offer.expires_at_ms
    with pytest.raises(StorageExpired):
        store.transition_pair_offer(
            offer.offer_id,
            expected="claimed",
            new_state="confirmed",
            device_id=device.device_id,
        )

    terminal = store.get_pair_offer(offer.offer_id)
    failed_closed = store.get_device(device.device_id, include_inactive=True)
    assert terminal.state == "expired"
    assert terminal.pair_secret == b"" and terminal.transport_token == ""
    assert failed_closed.status == "revoked"
    assert failed_closed.status_reason == "pair_offer_expired"
    assert failed_closed.hub_revocation_state == "pending"


def test_stream_outbox_is_exact_across_restart_and_ack(tmp_path) -> None:
    store = RelayStorage(tmp_path)
    device = _device(store)
    calls = 0

    def envelope(stream_id, first_seq, frames):
        nonlocal calls
        calls += 1
        assert first_seq == 1
        assert len(frames) == 2
        return {"mid": "frozen-mid", "ct": "opaque", "stream": stream_id}

    record = store.enqueue_frames(device, [{"kind": "a"}, {"kind": "b"}], envelope)
    assert (record.first_seq, record.last_seq, calls) == (1, 2, 1)
    store.mark_hub_accepted(device, record.message_id)
    store.close()

    reopened = RelayStorage(tmp_path)
    pending = reopened.pending_outbox(device)
    assert len(pending) == 1
    assert pending[0].envelope == record.envelope
    assert pending[0].state == "hub_accepted"
    assert reopened.get_stream(device).next_seq == 3
    assert reopened.acknowledge_stream(device, 2) == 1
    assert reopened.pending_outbox(device) == []


def test_storage_enforces_exact_json_stream_and_revision_boundaries(tmp_path) -> None:
    store = RelayStorage(tmp_path, clock=lambda: 100)
    outbound = _device(store, "outbound-boundary")
    with store.transaction() as conn:
        conn.execute(
            "UPDATE streams SET next_seq=?,checkpoint_revision=? WHERE device_id=?",
            (MAX_WIRE_INTEGER - 1, MAX_WIRE_INTEGER - 1, outbound),
        )

    record = store.enqueue_frames(
        outbound,
        [{"kind": "boundary"}],
        lambda stream, first, _frames: {
            "mid": "mid-boundary",
            "stream": stream,
            "first": first,
        },
        expires_at_ms=200,
    )
    assert (record.first_seq, record.last_seq) == (
        MAX_WIRE_INTEGER - 1,
        MAX_WIRE_INTEGER - 1,
    )
    assert store.get_stream(outbound).next_seq == MAX_WIRE_INTEGER
    with pytest.raises(StorageConflict, match="sequence space"):
        store.enqueue_frames(
            outbound,
            [{"kind": "exhausted"}],
            lambda *_args: {"mid": "never"},
            expires_at_ms=200,
        )

    checkpoint = store.enqueue_stream_checkpoint(
        outbound,
        lambda stream, through, revision: {
            "mid": "checkpoint-boundary",
            "stream": stream,
            "through": through,
            "revision": revision,
        },
        expires_at_ms=200,
    )
    assert checkpoint.last_seq == MAX_WIRE_INTEGER - 1
    assert store.get_stream(outbound).checkpoint_revision == MAX_WIRE_INTEGER
    with pytest.raises(StorageConflict, match="revision space"):
        store.enqueue_stream_checkpoint(
            outbound,
            lambda *_args: {"mid": "never"},
            expires_at_ms=200,
        )

    inbound = _device(store, "inbound-boundary")
    inbound_stream = store.get_stream(inbound)
    with store.transaction() as conn:
        conn.execute(
            "UPDATE streams SET received_through=? WHERE device_id=?",
            (MAX_WIRE_INTEGER - 1, inbound),
        )
    assert store.commit_inbound_batch(
        inbound,
        "mid-inbound-boundary",
        stream_id=inbound_stream.stream_id,
        first_seq=MAX_WIRE_INTEGER,
        frame_count=1,
        expires_at_ms=200,
    )
    assert store.get_stream(inbound).received_through == MAX_WIRE_INTEGER
    assert store.acknowledge_stream(inbound, 0) == 0
    for outside in (-1, MAX_WIRE_INTEGER + 1):
        with pytest.raises(StorageConflict, match="exact JSON integer"):
            store.acknowledge_stream(inbound, outside)
        with pytest.raises(StorageConflict, match="exact JSON integer"):
            store.commit_inbound_batch(
                inbound,
                f"mid-outside-{outside}",
                stream_id=inbound_stream.stream_id,
                first_seq=outside,
                frame_count=1,
                expires_at_ms=200,
            )

    assert (
        store.apply_checkpoint(
            "revision-boundary",
            snapshot_revision=MAX_WIRE_INTEGER,
            through_seq=0,
            replace=True,
            items=[],
            tombstones=[],
        )
        == "applied"
    )
    with pytest.raises(StorageConflict, match="exact JSON integer"):
        store.apply_checkpoint(
            "revision-overflow",
            snapshot_revision=MAX_WIRE_INTEGER + 1,
            through_seq=0,
            replace=True,
            items=[],
            tombstones=[],
        )


def test_inbound_replay_and_gap_are_rejected_before_application(tmp_path) -> None:
    store = RelayStorage(tmp_path, clock=lambda: 100)
    device = _device(store)
    applied: list[str] = []
    kwargs = dict(stream_id=store.get_stream(device).stream_id, expires_at_ms=200)
    assert store.commit_inbound_batch(
        device,
        "mid1",
        first_seq=1,
        frame_count=2,
        apply=lambda _conn: applied.append("once"),
        **kwargs,
    )
    assert not store.commit_inbound_batch(
        device,
        "mid1",
        first_seq=1,
        frame_count=2,
        apply=lambda _conn: applied.append("twice"),
        **kwargs,
    )
    with pytest.raises(StreamGap):
        store.commit_inbound_batch(
            device, "mid3", first_seq=4, frame_count=1, apply=None, **kwargs
        )
    assert applied == ["once"]
    assert store.get_stream(device).received_through == 2


def test_operation_idempotency_conflict_and_restart_ambiguity(tmp_path) -> None:
    store = RelayStorage(tmp_path)
    device = _device(store)
    params = {"client_message_id": "cmid_1234567890123456", "text": "hello"}
    first = store.begin_operation(device, "op_1", "prompt.submit", params)
    assert first.state == "received"
    store.mark_operation_executing(device, "op_1")
    store.close()

    reopened = RelayStorage(tmp_path)
    assert (
        reopened.begin_operation(device, "op_1", "prompt.submit", params).state
        == "ambiguous"
    )
    with pytest.raises(StorageConflict):
        reopened.begin_operation(
            device, "op_1", "prompt.submit", {**params, "text": "different"}
        )

    second = reopened.begin_operation(device, "op_2", "prompt.submit", params)
    reopened.mark_operation_executing(device, second.op_id)
    reopened.complete_operation(device, second.op_id, {"accepted": True})
    replay = reopened.begin_operation(device, "op_2", "prompt.submit", params)
    assert replay.state == "succeeded"
    assert replay.response == {"accepted": True}
    with pytest.raises(Exception):
        reopened.begin_operation(device, "op_nan", "prompt.submit", {"value": math.nan})
    with pytest.raises(Exception):
        reopened.begin_operation(device, "op_key", "prompt.submit", {1: "not-string"})


def test_revisioned_items_ignore_duplicate_delta_and_partition_sessions(
    tmp_path,
) -> None:
    store = RelayStorage(tmp_path)
    for session, text in (("s1", "hello"), ("s2", "other")):
        assert (
            store.put_full_item(
                session,
                {
                    "item_id": "same-id",
                    "turn_id": "turn",
                    "type": "agentMessage",
                    "status": "in_progress",
                    "ord": 0,
                    "rev": 1,
                    "body": {"text": text},
                },
            )
            == "applied"
        )
    delta = {
        "item_id": "same-id",
        "from_rev": 1,
        "to_rev": 2,
        "ops": [{"op": "append_utf8", "path": "/body/text", "offset": 5, "data": "!"}],
    }
    assert store.apply_item_delta("s1", delta) == "applied"
    assert store.apply_item_delta("s1", delta) == "duplicate"
    assert store.session_checkpoint("s1")["items"][0]["body"]["text"] == "hello!"
    assert store.session_checkpoint("s2")["items"][0]["body"]["text"] == "other"


def test_tombstone_dominates_and_equal_revision_divergence_conflicts(tmp_path) -> None:
    store = RelayStorage(tmp_path)
    item = {
        "item_id": "item",
        "type": "agentMessage",
        "status": "in_progress",
        "ord": 0,
        "rev": 1,
        "summary": "",
        "body": {"text": "a"},
    }
    assert store.put_full_item("s", item, source_item_id="source") == "applied"
    with pytest.raises(StorageConflict):
        store.put_full_item("s", {**item, "body": {"text": "different"}})
    delta = {
        "item_id": "item",
        "from_rev": 1,
        "to_rev": 2,
        "ops": [{"op": "append_utf8", "path": "/body/text", "offset": 1, "data": "b"}],
    }
    assert store.apply_item_delta("s", delta) == "applied"
    assert store.apply_item_delta("s", delta) == "duplicate"
    divergent = {**delta, "ops": [{**delta["ops"][0], "data": "c"}]}
    with pytest.raises(StorageConflict):
        store.apply_item_delta("s", divergent)
    assert (
        store.apply_checkpoint(
            "s",
            snapshot_revision=5,
            through_seq=2,
            replace=True,
            items=[],
            tombstones=[{"item_id": "item", "deleted_at_revision": 5}],
        )
        == "applied"
    )
    assert store.resolve_item_id("s", "source") == "item"
    assert store.put_full_item("s", {**item, "rev": 5}) == "tombstoned"
    assert store.put_full_item("s", {**item, "rev": 6}) == "applied"
    with pytest.raises(StorageConflict):
        store.apply_checkpoint(
            "s",
            snapshot_revision=5,
            through_seq=99,
            replace=True,
            items=[],
            tombstones=[],
        )


def test_aliases_and_presence_persist_per_device(tmp_path) -> None:
    store = RelayStorage(tmp_path)
    first, second = _device(store, "1"), _device(store, "2")
    store.own_session("origin", "live")
    store.set_subscription(first, "origin", foreground=True)
    store.set_subscription(second, "other", foreground=True)
    assert store.live_session_id("origin") == "live"
    assert store.session_has_foreground_device("origin")
    store.clear_presence(first)
    assert not store.session_has_foreground_device("origin")
    assert store.session_has_foreground_device("other")
    store.close()
    reopened = RelayStorage(tmp_path)
    assert reopened.owned_sessions() == {"origin": "live"}


def test_push_binding_exact_retry_erases_one_time_bind_token(tmp_path) -> None:
    protector = Protector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    device = store.register_device(
        device_id="dev_push",
        name="Phone",
        route="rte_push",
        kem_public=b"k" * 32,
        sign_public=b"s" * 32,
        preview_public=b"p" * 32,
    )
    exchange = store.prepare_push_binding_exchange(
        device_id=device.device_id,
        bind_token="one-time-bind-token",
        requested_classes=["approval", "update"],
    )
    store.complete_push_binding_exchange(
        device_id=device.device_id,
        exchange_id=exchange.exchange_id,
        binding_id="pb_1",
        send_capability=b"c" * 32,
        allowed_classes=["update", "approval"],
    )
    assert store.push_binding_exchange(device.device_id).bind_token == ""
    protected_count = len(protector.protected)
    store.complete_push_binding_exchange(
        device_id=device.device_id,
        exchange_id=exchange.exchange_id,
        binding_id="pb_1",
        send_capability=b"c" * 32,
        allowed_classes=["approval", "update"],
    )
    assert len(protector.protected) == protected_count
    assert any(b"one-time-bind-token" in wrapped for wrapped in protector.deleted)


def test_operational_summary_and_destroy_local_authority_are_content_free(
    tmp_path,
) -> None:
    protector = Protector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    store.store_identity(
        kem_private=protector.protect("kem", b"k" * 32),
        kem_public=b"K" * 32,
        sign_private=protector.protect("sign", b"s" * 32),
        sign_public=b"S" * 32,
    )
    device = _device(store, "purge")
    store.enqueue_frames(
        device,
        [{"kind": "status", "body": {"text": "must-not-leak"}}],
        lambda stream, first, _frames: {
            "mid": "mid_secret",
            "stream": stream,
            "first": first,
            "ct": "ciphertext",
        },
    )
    summary = store.operational_summary()
    assert summary["outbox"]["pending"]["count"] == 1
    assert "must-not-leak" not in repr(summary)
    assert "ciphertext" not in repr(summary)
    assert {row.status for row in store.devices()} == {"active"}

    store.destroy_local_authority()
    assert store.load_identity().kem_private == b""
    assert store.get_device(device, include_inactive=True).status == "revoked"
    assert protector.deleted
