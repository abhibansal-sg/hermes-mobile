-- Durable, content-free association used only to revoke an exchange.  These
-- rows intentionally outlive bounded response receipts and one-time tokens.
CREATE TABLE IF NOT EXISTS push_schema_migrations (
    version INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS binding_exchange_authorities (
    exchange_id_hash BYTEA PRIMARY KEY CHECK (octet_length(exchange_id_hash) = 32),
    bind_token_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(bind_token_hash) = 32),
    endpoint_id TEXT NOT NULL REFERENCES endpoints(endpoint_id),
    binding_id TEXT UNIQUE REFERENCES bindings(binding_id),
    created_at_ms BIGINT NOT NULL,
    revoked_at_ms BIGINT
);

INSERT INTO binding_exchange_authorities (
    exchange_id_hash,
    bind_token_hash,
    endpoint_id,
    binding_id,
    created_at_ms,
    revoked_at_ms
)
SELECT
    receipt.exchange_id_hash,
    receipt.bind_token_hash,
    receipt.endpoint_id,
    receipt.binding_id,
    binding.created_at_ms,
    binding.revoked_at_ms
FROM binding_exchange_receipts AS receipt
JOIN bindings AS binding ON binding.binding_id = receipt.binding_id
ON CONFLICT DO NOTHING;

INSERT INTO push_schema_migrations(version) VALUES (2)
ON CONFLICT DO NOTHING;
