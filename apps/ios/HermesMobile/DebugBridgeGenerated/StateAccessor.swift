// AUTO-GENERATED — DO NOT EDIT. Regenerate with /ios-sync.
#if DEBUG
import Foundation
import DebugBridgeCore

@MainActor
enum ChatStoreAccessor {
    static func register(_ state: ChatStore) {
        StateServer.shared.register(
            buildId: "0.1.0+df9543249",
            accessorHash: "3536558cb0640f6f89f25eb52120d02659144ee98d09092f0ff491512aeefb20",
            atomicRestore: { _ in .ok }
        )
        StateServer.shared.registerAccessor(
            key: "isStreaming",
            type: "Any",
            read: { state.isStreaming as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "lastError",
            type: "Any",
            read: { state.lastError as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "activeToolName",
            type: "Any",
            read: { state.activeToolName as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "lastBackfillError",
            type: "Any",
            read: { state.lastBackfillError as Any? },
            write: { _ in false }
        )
        // F3-H foreign-mirror adoption-gate telemetry. The @Snapshotable struct
        // is not JSON-serializable through StateServer's JSONSerialization sink,
        // so each counter is exposed as its own Int accessor (the same pattern
        // ConnectionStore.phaseLabel uses for its enum). DEBUG-only; absent in
        // Release.
        StateServer.shared.registerAccessor(
            key: "foreignMirror.foreignAdopted",
            type: "Any",
            read: { state.foreignMirrorTelemetry.foreignAdopted as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "foreignMirror.foreignDeltasApplied",
            type: "Any",
            read: { state.foreignMirrorTelemetry.foreignDeltasApplied as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "foreignMirror.foreignDroppedWhileStreaming",
            type: "Any",
            read: { state.foreignMirrorTelemetry.foreignDroppedWhileStreaming as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "foreignMirror.foreignCompletesReconciled",
            type: "Any",
            read: { state.foreignMirrorTelemetry.foreignCompletesReconciled as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "foreignMirror.backfillRuns",
            type: "Any",
            read: { state.foreignMirrorTelemetry.backfillRuns as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "foreignMirror.backfillFailures",
            type: "Any",
            read: { state.foreignMirrorTelemetry.backfillFailures as Any? },
            write: { _ in false }
        )
        // F3-H2 streaming-setter telemetry. `lastStreamingSetter` names the most
        // recent isStreaming writer (function + reason + the routed frame's
        // session_id/stored_session_id vs. the active ids); `streamingRing` is the
        // last 20 transitions encoded as a JSON string (StateServer's
        // JSONSerialization sink can't take the struct array directly). Together
        // they NAME the writer that flipped streaming true before the foreign
        // mirror gate ran. DEBUG-only; absent in Release.
        StateServer.shared.registerAccessor(
            key: "lastStreamingSetter",
            type: "Any",
            read: { state.lastStreamingSetter as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "streamingRing",
            type: "Any",
            read: { state.streamingRingJSON as Any? },
            write: { _ in false }
        )
        // F4A-A2 subagent-tree + secure-prompt observability for the integration
        // gate. `subagentNodeCount` lets the gate assert the tree assembled;
        // `activeSecurePromptKind` exposes only the prompt KIND ("sudo"/"secret"/
        // "none") so the gate can assert a prompt is up — the entered VALUE is
        // never held in the store, so it can never be read here. DEBUG-only.
        StateServer.shared.registerAccessor(
            key: "subagentNodeCount",
            type: "Any",
            read: { state.subagentNodeCount as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "activeSecurePromptKind",
            type: "Any",
            read: { state.activeSecurePromptKind as Any? },
            write: { _ in false }
        )
    }
}

@MainActor
enum ConnectionStoreAccessor {
    static func register(_ state: ConnectionStore) {
        StateServer.shared.register(
            buildId: "0.1.0+df9543249",
            accessorHash: "3536558cb0640f6f89f25eb52120d02659144ee98d09092f0ff491512aeefb20",
            atomicRestore: { _ in .ok }
        )
        StateServer.shared.registerAccessor(
            key: "phaseLabel",
            type: "Any",
            read: { state.phaseLabel as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "serverURLString",
            type: "Any",
            read: { state.serverURLString as Any? },
            write: { _ in false }
        )
        // F4a integration-gate observability: the file-browser feature-probe
        // state ("unknown"/"available"/"unavailable") so the gate can assert the
        // stock-degradation and patched-server transitions via the bridge. Read
        // side only; never mutable. DEBUG-only.
        StateServer.shared.registerAccessor(
            key: "fsCapability",
            type: "Any",
            read: { state.capabilities.fs.rawValue as Any? },
            write: { _ in false }
        )
        // F4b integration-gate observability (hand-added per CONTRACT-F4B.md
        // §Integration gate item 3, mirroring the `fsCapability` pattern above):
        // the multi-profile feature-probe state ("unknown"/"available"/
        // "unavailable"). On today's server (live 9119 / this-branch 9123) the
        // probe hits `GET /api/profiles/sessions` → 404 → "unavailable", which IS
        // the dormancy proof the gate asserts. Read side only; never mutable.
        // DEBUG-only; compiled out of Release.
        StateServer.shared.registerAccessor(
            key: "profilesCapability",
            type: "Any",
            read: { state.capabilities.profiles.rawValue as Any? },
            write: { _ in false }
        )
        // W3A-A integration-gate observability (hand-added per CONTRACT-W3A.md
        // §Integration gate item 6 + §SCOPE item 5, mirroring the `fsCapability`
        // pattern above — NOTE this file is hand-maintained; the codegen doesn't
        // parse this codebase, so these accessors are added by hand). The
        // per-device-token feature-probe state ("unknown"/"available"/
        // "unavailable"): on a stock server the probe hits `GET /api/devices` →
        // 404 → "unavailable", which IS the stock-degradation proof the gate
        // asserts (the Devices section hides + no auto-upgrade fires). Read side
        // only; never mutable. DEBUG-only; compiled out of Release.
        StateServer.shared.registerAccessor(
            key: "devicesCapability",
            type: "Any",
            read: { state.capabilities.devices.rawValue as Any? },
            write: { _ in false }
        )
        // Whether the Settings Devices section would render for this connection
        // (`devices == .available`). The gate's stock-degradation step asserts
        // this is false on a stock server. Read-only; DEBUG-only.
        StateServer.shared.registerAccessor(
            key: "devicesSectionVisible",
            type: "Any",
            read: { state.devicesSectionVisible as Any? },
            write: { _ in false }
        )
        // The recorded NON-SECRET `device_id` for the current server — the proof
        // the app auto-upgraded to a per-device token (nil ⇒ still on the shared
        // token). NEVER the token value (the device_id is the opaque, non-secret
        // handle; the token lives only in the Keychain). Read-only; DEBUG-only.
        StateServer.shared.registerAccessor(
            key: "recordedDeviceId",
            type: "Any",
            read: { state.recordedDeviceIdForCurrentServer as Any? },
            write: { _ in false }
        )
    }
}

@MainActor
enum InboxStoreAccessor {
    static func register(_ state: InboxStore) {
        StateServer.shared.register(
            buildId: "0.1.0+df9543249",
            accessorHash: "3536558cb0640f6f89f25eb52120d02659144ee98d09092f0ff491512aeefb20",
            atomicRestore: { _ in .ok }
        )
        StateServer.shared.registerAccessor(
            key: "pendingCount",
            type: "Any",
            read: { state.pendingCount as Any? },
            write: { _ in false }
        )
    }
}

@MainActor
enum SessionStoreAccessor {
    static func register(_ state: SessionStore) {
        StateServer.shared.register(
            buildId: "0.1.0+df9543249",
            accessorHash: "3536558cb0640f6f89f25eb52120d02659144ee98d09092f0ff491512aeefb20",
            atomicRestore: { _ in .ok }
        )
        StateServer.shared.registerAccessor(
            key: "activeStoredId",
            type: "Any",
            read: { state.activeStoredId as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "isLoading",
            type: "Any",
            read: { state.isLoading as Any? },
            write: { _ in false }
        )
        // F4b integration-gate observability (hand-added per CONTRACT-F4B.md
        // §Integration gate item 3, mirroring the `fsCapability` pattern in
        // ConnectionStoreAccessor): the switcher-visibility surfaces the dormancy
        // + double-gate proof hangs on. `switcherVisible` is the binding gate
        // (`capabilities.profiles == .available && profileCount > 1`) — false on
        // today's server, the dormancy guarantee; `profileCount` is the fetched
        // profile-list size (0 when dormant, since loadProfiles() short-circuits
        // on a non-available probe); `activeProfile` is the persisted scope pref
        // (already @Snapshotable-marked on the field, surfaced here). Read side
        // only; never mutable. DEBUG-only; compiled out of Release.
        StateServer.shared.registerAccessor(
            key: "switcherVisible",
            type: "Any",
            read: { state.isMultiProfileAvailable as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "profileCount",
            type: "Any",
            read: { state.profiles.count as Any? },
            write: { _ in false }
        )
        StateServer.shared.registerAccessor(
            key: "activeProfile",
            type: "Any",
            read: { state.activeProfile as Any? },
            write: { _ in false }
        )
    }
}

#endif
