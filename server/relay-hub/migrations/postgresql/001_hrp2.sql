BEGIN;

CREATE TABLE IF NOT EXISTS routes (
    route_id TEXT PRIMARY KEY,
    enrollment_id TEXT UNIQUE,
    auth_public_key BYTEA NOT NULL CHECK (octet_length(auth_public_key) = 32),
    route_type TEXT NOT NULL CHECK (route_type IN ('agent', 'device')),
    status TEXT NOT NULL CHECK (status IN ('provisional', 'pending', 'active', 'revoked')),
    created_at_ms BIGINT NOT NULL,
    expires_at_ms BIGINT,
    activated_at_ms BIGINT,
    revoked_at_ms BIGINT,
    owner_route TEXT,
    pair_offer_id TEXT,
    pending_control_used_at_ms BIGINT
);
CREATE UNIQUE INDEX IF NOT EXISTS routes_pair_offer
    ON routes(pair_offer_id) WHERE pair_offer_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS provisional_enrollment_events (
    source_hash BYTEA NOT NULL CHECK (octet_length(source_hash) = 32),
    event_id BYTEA NOT NULL CHECK (octet_length(event_id) = 16),
    expires_at_ms BIGINT NOT NULL,
    PRIMARY KEY (source_hash, event_id)
);
CREATE INDEX IF NOT EXISTS provisional_enrollment_events_expiry
    ON provisional_enrollment_events(expires_at_ms);

CREATE TABLE IF NOT EXISTS grants (
    grant_id TEXT PRIMARY KEY,
    issuer_route TEXT NOT NULL REFERENCES routes(route_id),
    source_route TEXT NOT NULL REFERENCES routes(route_id),
    destination_route TEXT NOT NULL REFERENCES routes(route_id),
    permissions INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'revoked')),
    issuer_signature BYTEA NOT NULL CHECK (octet_length(issuer_signature) = 64),
    created_at_ms BIGINT NOT NULL,
    expires_at_ms BIGINT,
    revoked_at_ms BIGINT
);
CREATE UNIQUE INDEX IF NOT EXISTS grants_active_route_pair
    ON grants(source_route, destination_route) WHERE revoked_at_ms IS NULL;

CREATE TABLE IF NOT EXISTS messages (
    destination_route TEXT NOT NULL REFERENCES routes(route_id),
    message_id BYTEA NOT NULL CHECK (octet_length(message_id) = 16),
    source_route TEXT NOT NULL REFERENCES routes(route_id),
    message_class TEXT NOT NULL CHECK (message_class IN ('state', 'command', 'control')),
    expires_at_ms BIGINT NOT NULL,
    collapse_id BYTEA,
    key_generation INTEGER NOT NULL CHECK (key_generation > 0),
    hpke_enc BYTEA NOT NULL,
    ciphertext BYTEA NOT NULL,
    sender_signature BYTEA NOT NULL CHECK (octet_length(sender_signature) = 64),
    size_bytes INTEGER NOT NULL CHECK (size_bytes > 0),
    created_at_ms BIGINT NOT NULL,
    delivered_at_ms BIGINT,
    PRIMARY KEY (destination_route, message_id)
);
CREATE INDEX IF NOT EXISTS messages_delivery
    ON messages(destination_route, created_at_ms);
CREATE INDEX IF NOT EXISTS messages_expiry ON messages(expires_at_ms);
CREATE INDEX IF NOT EXISTS messages_state_collapse
    ON messages(destination_route, collapse_id) WHERE message_class = 'state';

CREATE TABLE IF NOT EXISTS message_receipts (
    destination_route TEXT NOT NULL,
    message_id BYTEA NOT NULL CHECK (octet_length(message_id) = 16),
    envelope_hash BYTEA NOT NULL CHECK (octet_length(envelope_hash) = 32),
    expires_at_ms BIGINT NOT NULL,
    created_at_ms BIGINT NOT NULL,
    PRIMARY KEY (destination_route, message_id)
);
CREATE INDEX IF NOT EXISTS message_receipts_expiry ON message_receipts(expires_at_ms);
CREATE INDEX IF NOT EXISTS message_receipts_admission
    ON message_receipts(destination_route, created_at_ms);

CREATE TABLE IF NOT EXISTS request_nonces (
    route_id TEXT NOT NULL,
    nonce BYTEA NOT NULL CHECK (octet_length(nonce) = 16),
    expires_at_ms BIGINT NOT NULL,
    PRIMARY KEY (route_id, nonce)
);
CREATE INDEX IF NOT EXISTS request_nonces_expiry ON request_nonces(expires_at_ms);

CREATE TABLE IF NOT EXISTS activation_receipts (
    token_hash BYTEA PRIMARY KEY CHECK (octet_length(token_hash) = 32),
    route_id TEXT NOT NULL,
    used_at_ms BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS pair_offers (
    offer_id TEXT PRIMARY KEY,
    offer_route TEXT NOT NULL UNIQUE,
    owner_route TEXT NOT NULL REFERENCES routes(route_id),
    transport_token_hash BYTEA NOT NULL CHECK (octet_length(transport_token_hash) = 32),
    expires_at_ms BIGINT NOT NULL,
    created_at_ms BIGINT NOT NULL,
    hpke_enc BYTEA,
    ciphertext BYTEA,
    message_hash BYTEA,
    claimed_at_ms BIGINT,
    device_route TEXT REFERENCES routes(route_id),
    response_enc BYTEA,
    response_ciphertext BYTEA,
    response_hash BYTEA,
    accepted_at_ms BIGINT,
    CHECK (hpke_enc IS NULL OR octet_length(hpke_enc) = 32),
    CHECK (message_hash IS NULL OR octet_length(message_hash) = 32),
    CHECK (response_enc IS NULL OR octet_length(response_enc) = 32),
    CHECK (response_hash IS NULL OR octet_length(response_hash) = 32)
);
CREATE INDEX IF NOT EXISTS pair_offers_owner_expiry ON pair_offers(owner_route, expires_at_ms);

CREATE TABLE IF NOT EXISTS pair_confirm_receipts (
    offer_id_hash BYTEA PRIMARY KEY CHECK (octet_length(offer_id_hash) = 32),
    owner_route TEXT NOT NULL,
    device_route TEXT NOT NULL,
    message_hash BYTEA NOT NULL CHECK (octet_length(message_hash) = 32),
    response_hash BYTEA NOT NULL CHECK (octet_length(response_hash) = 32),
    grant_id_1 TEXT NOT NULL,
    grant_id_2 TEXT NOT NULL,
    expires_at_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS pair_confirm_receipts_expiry
    ON pair_confirm_receipts(expires_at_ms);

COMMIT;
