import WidgetKit
import SwiftUI

/// Entry point for the Hermes widget extension. Bundles the home-screen
/// widgets and the Live Activity. The extension target compiles
/// `SharedStore.swift` (same module) for app-group access.
@main
struct HermesWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        UsageWidget()
        if #available(iOS 16.1, *) {
            HermesTurnLiveActivity()
        }
    }
}
