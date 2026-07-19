from __future__ import annotations

from pathlib import Path
import sqlite3

from fastapi.testclient import TestClient

from push_gateway.app import create_app
from push_gateway.settings import Settings
from push_gateway.storage import DatabaseStore


def test_sqlite_001_to_004_upgrade_backfills_security_state(
    tmp_path,
) -> None:
    root = Path(__file__).resolve().parents[1]
    database = tmp_path / "push.sqlite3"
    conn = sqlite3.connect(database)
    conn.executescript((root / "migrations/sqlite/001_hrp2.sql").read_text())
    conn.execute(
        """INSERT INTO attest_keys
           (key_id_hash,public_key_der,counter,bundle_id,environment,
            created_at_ms,updated_at_ms)
           VALUES (?,?,?,?,?,?,?)""",
        (b"k" * 32, b"public", 1, "ai.hermes.app", "production", 1, 1),
    )
    conn.execute(
        """INSERT INTO endpoints
           (endpoint_id,token_ciphertext,token_nonce,wrapped_data_key,wrap_nonce,
            key_version,environment,bundle_id,preview_kem_pub,
            installation_nonce_hash,attest_key_hash,status,created_at_ms,updated_at_ms)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            "ep_existing",
            b"ciphertext",
            b"n" * 12,
            b"wrapped",
            b"w" * 12,
            1,
            "production",
            "ai.hermes.app",
            b"p" * 32,
            b"i" * 32,
            b"k" * 32,
            "active",
            1,
            1,
        ),
    )
    conn.execute(
        """INSERT INTO bindings
           (binding_id,endpoint_id,capability_hash,allowed_classes,created_at_ms)
           VALUES (?,?,?,?,?)""",
        ("pb_existing", "ep_existing", b"c" * 32, 1, 10),
    )
    conn.execute(
        """INSERT INTO binding_exchange_receipts
           (exchange_id_hash,bind_token_hash,request_hash,binding_id,endpoint_id,
            allowed_classes,capability_ciphertext,capability_nonce,wrapped_data_key,
            wrap_nonce,key_version,expires_at_ms)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            b"e" * 32,
            b"b" * 32,
            b"r" * 32,
            "pb_existing",
            "ep_existing",
            1,
            b"ciphertext",
            b"n" * 12,
            b"wrapped",
            b"w" * 12,
            1,
            100,
        ),
    )
    conn.execute(
        """INSERT INTO attest_challenges
           (challenge_hash,created_at_ms,source_hash,expires_at_ms)
           VALUES (?,?,?,?)""",
        (b"h" * 32, 1, b"s" * 32, 1_000_000),
    )
    conn.execute(
        """INSERT INTO push_receipts
           (binding_id,notification_id_hash,request_hash,status,provider_status,
            apns_id,collapse_id,attempt_count,last_attempt_at_ms,created_at_ms,
            expires_at_ms,completed_at_ms)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            "pb_existing",
            b"n" * 32,
            b"q" * 32,
            "retryable",
            503,
            "00000000-0000-0000-0000-000000000001",
            "stable-collapse",
            3,
            99,
            10,
            1_000_000,
            99,
        ),
    )
    conn.commit()

    settings = Settings(
        database_url=f"sqlite:///{database}",
        token_master_key=b"m" * 32,
        capability_pepper=b"p" * 32,
        apple_app_id="TEAM.ai.hermes.app",
        require_apns=False,
        auto_create_schema=False,
    )
    store = DatabaseStore(settings)
    assert store.ready() is False
    with TestClient(create_app(settings=settings, store=store)) as client:
        stale = client.get("/readyz")
        assert stale.status_code == 503
        assert stale.json() == {"status": "not_ready"}

        migration = (
            root / "migrations/sqlite/002_binding_exchange_revocation.sql"
        ).read_text()
        conn.executescript(migration)
        conn.executescript(migration)
        assert store.ready() is False
        lease_migration = (
            root / "migrations/sqlite/003_push_send_attempt_leases.sql"
        ).read_text()
        conn.executescript(lease_migration)
        conn.executescript(lease_migration)
        assert store.ready() is False
        security_migration = (
            root
            / "migrations/sqlite/004_attestation_reservations_and_send_attempts.sql"
        ).read_text()
        conn.executescript(security_migration)
        conn.executescript(security_migration)
        assert store.ready() is True
        upgraded = client.get("/readyz")
        assert upgraded.status_code == 200
        assert upgraded.json() == {"status": "ready"}
    row = conn.execute(
        """SELECT exchange_id_hash,bind_token_hash,endpoint_id,binding_id,
                  created_at_ms,revoked_at_ms
           FROM binding_exchange_authorities"""
    ).fetchone()
    assert row == (b"e" * 32, b"b" * 32, "ep_existing", "pb_existing", 10, None)
    assert conn.execute("SELECT version FROM push_schema_migrations").fetchall() == [
        (2,),
        (3,),
        (4,),
    ]
    assert {
        row[1] for row in conn.execute("PRAGMA table_info(push_receipts)").fetchall()
    } >= {
        "attempt_token",
        "lease_expires_at_ms",
        "provider_retry_not_before_ms",
    }
    assert {
        row[1]
        for row in conn.execute("PRAGMA table_info(attest_challenges)").fetchall()
    } >= {
        "validation_request_hash",
        "validation_owner_token",
        "validation_expires_at_ms",
    }
    assert conn.execute(
        """SELECT attempt_number,attempted_at_ms
           FROM push_send_attempts
           WHERE binding_id = ? ORDER BY attempt_number""",
        ("pb_existing",),
    ).fetchall() == [(1, 99), (2, 99), (3, 99)]
    store.engine.dispose()
    conn.close()


def test_push_compose_runs_every_ordered_migration_and_dialects_stay_in_parity() -> (
    None
):
    repository = Path(__file__).resolve().parents[3]
    migration_names = sorted(
        path.name
        for path in (repository / "server/push-gateway/migrations/postgresql").glob(
            "*.sql"
        )
    )
    assert migration_names == [
        "001_hrp2.sql",
        "002_binding_exchange_revocation.sql",
        "003_push_send_attempt_leases.sql",
        "004_attestation_reservations_and_send_attempts.sql",
    ]

    for compose_path in (
        repository / "server/compose.hrp2.yml",
        repository / "server/push-gateway/compose.example.yml",
    ):
        source = compose_path.read_text()
        if compose_path.name == "compose.hrp2.yml":
            source = source.split("  push-gateway-migrate:", 1)[1].split(
                "  push-gateway:", 1
            )[0]
        else:
            source = source.split("  migrate:", 1)[1].split("  push-gateway:", 1)[0]
        assert "migrations/postgresql:/migrations:ro" in source
        assert "for migration in /migrations/*.sql" in source
        assert "ON_ERROR_STOP=1" in source
        assert "/migration.sql" not in source

    sqlite_source = (
        repository
        / "server/push-gateway/migrations/sqlite/002_binding_exchange_revocation.sql"
    ).read_text()
    postgres_source = (
        repository
        / "server/push-gateway/migrations/postgresql/002_binding_exchange_revocation.sql"
    ).read_text()
    for required in (
        "binding_exchange_authorities",
        "exchange_id_hash",
        "bind_token_hash",
        "binding_id",
        "revoked_at_ms",
        "push_schema_migrations",
        "VALUES (2)",
    ):
        assert required in sqlite_source
        assert required in postgres_source

    for dialect in ("sqlite", "postgresql"):
        lease_source = (
            repository
            / f"server/push-gateway/migrations/{dialect}/003_push_send_attempt_leases.sql"
        ).read_text()
        assert "attempt_token" in lease_source
        assert "lease_expires_at_ms" in lease_source
        assert "provider_retry_not_before_ms" in lease_source
        assert "VALUES (3)" in lease_source
        security_source = (
            repository
            / f"server/push-gateway/migrations/{dialect}/004_attestation_reservations_and_send_attempts.sql"
        ).read_text()
        for required in (
            "validation_request_hash",
            "validation_owner_token",
            "validation_expires_at_ms",
            "push_send_attempts",
            "attempt_number",
            "VALUES (4)",
        ):
            assert required in security_source
