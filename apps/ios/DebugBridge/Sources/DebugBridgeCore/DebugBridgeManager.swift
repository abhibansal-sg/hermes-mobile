// Installed from gstack/ios-qa/templates/DebugBridgeManager.swift.template
// (task UI-G), adapted for HermesMobile's multi-store composition root.
//
// Bootstraps StateServer on app launch. Lives in DebugBridgeCore (no UIKit
// dependency). The DebugBridgeUI bridges (screenshot / elements / mutation)
// and the DebugOverlay are wired separately by the consuming app — they live
// in DebugBridgeUI, which depends on DebugBridgeCore (not the other way
// around). Everything is #if DEBUG-gated; this file does not exist in Release
// builds.
//
// HermesMobile has no single canonical AppState struct; it has a graph of
// independent @Observable stores built in AppEnvironment. So instead of the
// template's `AppStateAccessor.register(appState)` single-struct hook, the
// manager takes a `registerAccessors` closure that the app's #if DEBUG wiring
// fills with the generated per-store `…Accessor.register(store)` calls.

#if DEBUG

import Foundation

@MainActor
public final class DebugBridgeManager {
    public static let shared = DebugBridgeManager()

    private var started = false

    /// Boot the bridge.
    ///
    /// - Parameter registerAccessors: closure that registers the generated
    ///   read accessors against `StateServer.shared`. The app's wiring passes
    ///   the per-store `…Accessor.register(_:)` calls here (see
    ///   `DebugBridgeWiring.swift`).
    public func start(registerAccessors: () -> Void = {}) {
        guard !started else { return }
        started = true

        // 1. Register the generated accessors so the first snapshot request has
        //    a populated registry.
        registerAccessors()

        // 2. Boot the StateServer (loopback-only HTTP surface).
        StateServer.shared.start()

        // 3. The consuming app installs the UIKit bridges + DebugOverlay
        //    separately from DebugBridgeUI. See DebugBridgeWiring.swift.
    }
}

// Marker protocol for an app's canonical state object. HermesMobile uses a
// store graph rather than one struct, so this is kept for API parity with the
// upstream template and is not required by the manager.
@MainActor
public protocol AppState: AnyObject {}

#endif // DEBUG
