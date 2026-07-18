import Foundation

/// Pure decision logic that reconciles a persisted gateway-forget cleanup
/// tombstone against the CURRENT pairing identity for its server.
///
/// A forget writes a ``GatewayCleanupTombstone`` for two independent reasons:
///  1. so an interrupted LOCAL cleanup (credentials removed, but a later
///     idempotent owner not yet run) resumes at the next launch, and
///  2. so a failed REMOTE token-revoke of the forgotten device is retried.
///
/// These two concerns were conflated: the mere presence of a tombstone for a
/// server suppressed that server's cached drawer/transcript paint at cold-open.
/// Once the user RE-PAIRS the same server under a NEW device, the stale
/// tombstone must no longer suppress the re-paired server's cache — otherwise a
/// cold-open paints an empty "Not connected" shell over a fully-populated local
/// cache. Only the best-effort remote revoke of the OLD device remains owed, and
/// it must never gate the cache/paint.
enum GatewayForgetCoordinator {
    /// The reconciliation outcome for a single pending tombstone.
    struct Decision: Equatable, Sendable {
        /// Whether the tombstone still authorizes LOCAL forget semantics — i.e.
        /// the cache paint for its server may be skipped/cleared. `false` once a
        /// re-pair under a new device supersedes the forget.
        var suppressesCache: Bool
        /// The OLD device still owed a best-effort remote revoke, or `nil` when
        /// nothing remains owed remotely. Never gates the cache/paint.
        var remoteRevokeDeviceId: String?
        /// How the persisted tombstone should be rewritten after this decision.
        var rewrite: Rewrite

        enum Rewrite: Equatable, Sendable {
            /// Leave the persisted tombstone exactly as-is.
            case keep
            /// Rewrite to the superseded (retry-only) form: cache-suppression is
            /// void, the remote revoke of the old device is preserved.
            case supersede
            /// Nothing left owed — delete the tombstone entirely.
            case remove
        }
    }

    /// Evaluate a pending tombstone against the live pairing.
    ///
    /// - Parameters:
    ///   - tombstone: the pending cleanup tombstone.
    ///   - currentDeviceId: the device id currently paired to `tombstone.server`
    ///     (`nil` when the server holds no current device pairing).
    ///   - hasLivePairing: whether a live credential currently exists for
    ///     `tombstone.server` (its persisted URL is configured and/or a Keychain
    ///     token is present).
    static func evaluate(
        tombstone: GatewayCleanupTombstone,
        currentDeviceId: String?,
        hasLivePairing: Bool
    ) -> Decision {
        // Re-pairing supersedes forget ONLY when the server is live again under a
        // device that is NOT the forgotten one. A `nil` current device (or a
        // device equal to the tombstone's) is never a supersede — real forget
        // semantics stay.
        let repairedUnderNewDevice = hasLivePairing
            && currentDeviceId != nil
            && currentDeviceId != tombstone.deviceId

        guard repairedUnderNewDevice else {
            // Forget semantics preserved: the tombstone still suppresses the
            // cache. (deviceId == current pairing, or no live pairing at all.)
            return Decision(
                suppressesCache: true,
                remoteRevokeDeviceId: tombstone.remoteRetryNeeded ? tombstone.deviceId : nil,
                rewrite: .keep
            )
        }

        // The re-paired server's cache must ALWAYS paint. Keep only the owed
        // remote revoke of the old device, if any.
        if tombstone.remoteRetryNeeded, let old = tombstone.deviceId {
            return Decision(
                suppressesCache: false,
                remoteRevokeDeviceId: old,
                rewrite: .supersede
            )
        }
        // Nothing owed remotely — the tombstone has no remaining purpose.
        return Decision(suppressesCache: false, remoteRevokeDeviceId: nil, rewrite: .remove)
    }
}
