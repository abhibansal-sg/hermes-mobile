# HRP/2 conformance sources

`schema.json` freezes the shared pairing offer/handshake, outer envelope,
kind-specific secure-message bodies, frame/checkpoint/item lifecycle, JSON-RPC,
control receipts, and encrypted notification/action shapes. Runtime
implementations additionally enforce decoded byte lengths, canonical unpadded
base64url, UTF-8 byte limits, timestamp/revision relationships, class/kind
compatibility, and cross-field identity/stream invariants.

Wire integers use the exact cross-runtime JSON subset, with
`9007199254740991` (`2^53 - 1`) as the inclusive maximum even when a field is
logically unsigned. This remains safely inside SQLite and Swift `Int64` while
round-tripping exactly through Swift's Double-backed JSON model.
`frame_batch.first_seq` begins at one; zero remains valid for a fresh stream's
checkpoint and acknowledgement boundary.

`fixtures/auth-envelope.json` and `fixtures/notification-preview.json` are
non-secret deterministic test vectors for authenticated HPKE using
X25519/HKDF-SHA256/ChaCha20-Poly1305. The envelope fixture also includes the
outer Ed25519 authorization signature. They contain test-only private keys so
Python, the Relay Hub, the Push Gateway, and Swift can independently verify the
same bytes. They must never be used to derive production keys.

The notification fixture includes the complete per-device approval capability
shape used by both the NSE and main-app re-authentication path. The envelope
fixture contains an authoritative checkpoint, not a transport-only ACK.

Changing either fixture or any exact schema definition is a protocol change.
Update the Relay, Hub/Push, and Swift conformance suites in the same commit;
never accept a fixture change merely to make one implementation's output pass.
