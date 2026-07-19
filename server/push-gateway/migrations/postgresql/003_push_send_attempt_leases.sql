BEGIN;

ALTER TABLE push_receipts
    ADD COLUMN IF NOT EXISTS attempt_token BYTEA,
    ADD COLUMN IF NOT EXISTS lease_expires_at_ms BIGINT,
    ADD COLUMN IF NOT EXISTS provider_retry_not_before_ms BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'push_receipts_attempt_token_length'
    ) THEN
        ALTER TABLE push_receipts
            ADD CONSTRAINT push_receipts_attempt_token_length
            CHECK (attempt_token IS NULL OR octet_length(attempt_token) = 32);
    END IF;
END $$;

-- A migration is applied while the old process is stopped, so any prior
-- reservation is safely reclaimable by the new process.
UPDATE push_receipts
SET attempt_token = NULL, lease_expires_at_ms = NULL
WHERE status = 'reserved';

INSERT INTO push_schema_migrations(version) VALUES (3)
ON CONFLICT DO NOTHING;

COMMIT;
