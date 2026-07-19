BEGIN;

ALTER TABLE attest_challenges
    ADD COLUMN IF NOT EXISTS validation_request_hash BYTEA,
    ADD COLUMN IF NOT EXISTS validation_owner_token BYTEA,
    ADD COLUMN IF NOT EXISTS validation_expires_at_ms BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'attest_challenges_validation_request_hash_length'
    ) THEN
        ALTER TABLE attest_challenges ADD CONSTRAINT
            attest_challenges_validation_request_hash_length
            CHECK (
                validation_request_hash IS NULL
                OR octet_length(validation_request_hash) = 32
            );
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'attest_challenges_validation_owner_token_length'
    ) THEN
        ALTER TABLE attest_challenges ADD CONSTRAINT
            attest_challenges_validation_owner_token_length
            CHECK (
                validation_owner_token IS NULL
                OR octet_length(validation_owner_token) = 32
            );
    END IF;
END $$;

-- Migrations run with old workers stopped. No cryptographic validation can
-- survive that stop, so stale reservations become reusable after deployment.
UPDATE attest_challenges
SET validation_request_hash = NULL,
    validation_owner_token = NULL,
    validation_expires_at_ms = NULL
WHERE used_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS push_send_attempts (
    binding_id TEXT NOT NULL REFERENCES bindings(binding_id),
    notification_id_hash BYTEA NOT NULL CHECK (octet_length(notification_id_hash) = 32),
    attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
    attempted_at_ms BIGINT NOT NULL,
    PRIMARY KEY (binding_id, notification_id_hash, attempt_number)
);
CREATE INDEX IF NOT EXISTS push_send_attempts_rate
    ON push_send_attempts(binding_id, attempted_at_ms);
CREATE INDEX IF NOT EXISTS push_send_attempts_expiry
    ON push_send_attempts(attempted_at_ms);

INSERT INTO push_send_attempts (
    binding_id,notification_id_hash,attempt_number,attempted_at_ms
)
SELECT
    receipt.binding_id,
    receipt.notification_id_hash,
    attempt_number,
    receipt.last_attempt_at_ms
FROM push_receipts AS receipt
CROSS JOIN LATERAL generate_series(1, receipt.attempt_count) AS attempt_number
ON CONFLICT DO NOTHING;

INSERT INTO push_schema_migrations(version) VALUES (4)
ON CONFLICT DO NOTHING;

COMMIT;
