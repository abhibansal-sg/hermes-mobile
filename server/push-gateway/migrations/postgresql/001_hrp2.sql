BEGIN;

CREATE TABLE IF NOT EXISTS attest_challenges (
    challenge_hash BYTEA PRIMARY KEY CHECK (octet_length(challenge_hash) = 32),
    created_at_ms BIGINT NOT NULL,
    source_hash BYTEA NOT NULL CHECK (octet_length(source_hash) = 32),
    expires_at_ms BIGINT NOT NULL,
    used_at_ms BIGINT,
    bound_request_hash BYTEA
);
CREATE INDEX IF NOT EXISTS attest_challenges_expiry ON attest_challenges(expires_at_ms);

CREATE TABLE IF NOT EXISTS registration_receipts (
    challenge_hash BYTEA PRIMARY KEY CHECK (octet_length(challenge_hash) = 32),
    request_hash BYTEA NOT NULL CHECK (octet_length(request_hash) = 32),
    key_id_hash BYTEA NOT NULL CHECK (octet_length(key_id_hash) = 32),
    endpoint_id TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('production', 'sandbox')),
    response_ciphertext BYTEA NOT NULL,
    response_nonce BYTEA NOT NULL CHECK (octet_length(response_nonce) = 12),
    wrapped_data_key BYTEA NOT NULL,
    wrap_nonce BYTEA NOT NULL CHECK (octet_length(wrap_nonce) = 12),
    key_version INTEGER NOT NULL,
    expires_at_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS registration_receipts_expiry
    ON registration_receipts(expires_at_ms);

CREATE TABLE IF NOT EXISTS hub_activation_receipts (
    challenge_hash BYTEA PRIMARY KEY CHECK (octet_length(challenge_hash) = 32),
    request_hash BYTEA NOT NULL CHECK (octet_length(request_hash) = 32),
    key_id_hash BYTEA NOT NULL CHECK (octet_length(key_id_hash) = 32),
    route_id TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('production', 'sandbox')),
    response_ciphertext BYTEA NOT NULL,
    response_nonce BYTEA NOT NULL CHECK (octet_length(response_nonce) = 12),
    wrapped_data_key BYTEA NOT NULL,
    wrap_nonce BYTEA NOT NULL CHECK (octet_length(wrap_nonce) = 12),
    key_version INTEGER NOT NULL,
    expires_at_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS hub_activation_receipts_expiry
    ON hub_activation_receipts(expires_at_ms);

CREATE TABLE IF NOT EXISTS attest_keys (
    key_id_hash BYTEA PRIMARY KEY CHECK (octet_length(key_id_hash) = 32),
    public_key_der BYTEA NOT NULL,
    counter BIGINT NOT NULL CHECK (counter > 0),
    bundle_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('production', 'sandbox')),
    created_at_ms BIGINT NOT NULL,
    updated_at_ms BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS endpoints (
    endpoint_id TEXT PRIMARY KEY,
    token_ciphertext BYTEA NOT NULL,
    token_nonce BYTEA NOT NULL CHECK (octet_length(token_nonce) = 12),
    wrapped_data_key BYTEA NOT NULL,
    wrap_nonce BYTEA NOT NULL CHECK (octet_length(wrap_nonce) = 12),
    key_version INTEGER NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('production', 'sandbox')),
    bundle_id TEXT NOT NULL,
    preview_kem_pub BYTEA NOT NULL CHECK (octet_length(preview_kem_pub) = 32),
    installation_nonce_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(installation_nonce_hash) = 32),
    attest_key_hash BYTEA NOT NULL REFERENCES attest_keys(key_id_hash),
    status TEXT NOT NULL CHECK (status IN ('active', 'disabled', 'revoked')),
    created_at_ms BIGINT NOT NULL,
    updated_at_ms BIGINT NOT NULL,
    disabled_at_ms BIGINT
);

CREATE TABLE IF NOT EXISTS bind_tokens (
    token_hash BYTEA PRIMARY KEY CHECK (octet_length(token_hash) = 32),
    endpoint_id TEXT NOT NULL REFERENCES endpoints(endpoint_id),
    expires_at_ms BIGINT NOT NULL,
    used_at_ms BIGINT,
    created_at_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS bind_tokens_expiry ON bind_tokens(expires_at_ms);

CREATE TABLE IF NOT EXISTS bindings (
    binding_id TEXT PRIMARY KEY,
    endpoint_id TEXT NOT NULL REFERENCES endpoints(endpoint_id),
    capability_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(capability_hash) = 32),
    allowed_classes INTEGER NOT NULL CHECK (allowed_classes BETWEEN 1 AND 7),
    created_at_ms BIGINT NOT NULL,
    revoked_at_ms BIGINT
);

CREATE TABLE IF NOT EXISTS binding_exchange_receipts (
    exchange_id_hash BYTEA PRIMARY KEY CHECK (octet_length(exchange_id_hash) = 32),
    bind_token_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(bind_token_hash) = 32),
    request_hash BYTEA NOT NULL CHECK (octet_length(request_hash) = 32),
    binding_id TEXT NOT NULL,
    endpoint_id TEXT NOT NULL,
    allowed_classes INTEGER NOT NULL CHECK (allowed_classes BETWEEN 1 AND 7),
    capability_ciphertext BYTEA NOT NULL,
    capability_nonce BYTEA NOT NULL CHECK (octet_length(capability_nonce) = 12),
    wrapped_data_key BYTEA NOT NULL,
    wrap_nonce BYTEA NOT NULL CHECK (octet_length(wrap_nonce) = 12),
    key_version INTEGER NOT NULL,
    expires_at_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS binding_exchange_receipts_expiry
    ON binding_exchange_receipts(expires_at_ms);

CREATE TABLE IF NOT EXISTS push_receipts (
    binding_id TEXT NOT NULL REFERENCES bindings(binding_id),
    notification_id_hash BYTEA NOT NULL CHECK (octet_length(notification_id_hash) = 32),
    request_hash BYTEA NOT NULL CHECK (octet_length(request_hash) = 32),
    status TEXT NOT NULL CHECK (status IN ('reserved', 'ambiguous', 'retryable', 'sent', 'permanent_rejected')),
    provider_status INTEGER,
    apns_id TEXT NOT NULL,
    collapse_id TEXT NOT NULL,
    attempt_count INTEGER NOT NULL CHECK (attempt_count > 0),
    last_attempt_at_ms BIGINT NOT NULL,
    provider_retry_not_before_ms BIGINT,
    created_at_ms BIGINT NOT NULL,
    expires_at_ms BIGINT NOT NULL,
    completed_at_ms BIGINT,
    PRIMARY KEY (binding_id, notification_id_hash)
);
CREATE INDEX IF NOT EXISTS push_receipts_rate ON push_receipts(binding_id, created_at_ms);
CREATE INDEX IF NOT EXISTS push_receipts_expiry ON push_receipts(expires_at_ms);

COMMIT;
