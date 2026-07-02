import CoreSpotlight
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct HermesMobileApp: App {
    @State private var environment = AppEnvironment()
    /// Carries a deferred `hermesapp://pair` payload from `onOpenURL` up to the
    /// confirmation UI in `RootView` (re-pairing while connected is destructive).
    @State private var deepLink = DeepLinkCoordinator()
    @State private var sharedInboxToast: String?
    @State private var sharedInboxToastDismissTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    /// APNs token callbacks only reach a `UIApplicationDelegate`; this adaptor
    /// forwards them to `PushRegistrar` (see ``AppDelegate``).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.installTransparentNavigationBarAppearance()
    }

    /// Force a fully transparent navigation-bar appearance app-wide. This is the
    /// root cause of the user's top "white strip": on iOS 26 the SwiftUI
    /// `.toolbarBackground(.hidden)` / `.toolbarBackgroundVisibility(.hidden)`
    /// modifiers are silently overridden by the system's automatic opaque
    /// scroll-edge nav-bar appearance the moment transcript content scrolls under
    /// the bar — UINavigationBar falls back to `scrollEdgeAppearance`/
    /// `standardAppearance`, both of which default to an OPAQUE system-background
    /// fill (the white band the user sees from the status bar through the toolbar).
    /// Configuring BOTH appearances with a transparent background + clear shadow
    /// at the UIKit proxy level is the only treatment that holds on 26, so the
    /// full-bleed `theme.bg` chat canvas painted behind the bar shows through and
    /// the toolbar items float as bare glass over it. The compact chat is the only
    /// surface that wants a transparent bar; the iPad split detail re-asserts its
    /// own themed opaque bar via the SwiftUI `.toolbarBackground(.visible)` path
    /// in `applyingChatToolbarBackground`, which overrides this proxy default on
    /// that surface only.
    #if canImport(UIKit)
    @MainActor
    private static func installTransparentNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.backgroundEffect = nil
        appearance.shadowColor = .clear
        appearance.shadowImage = UIImage()
        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = appearance
        proxy.compactAppearance = appearance
        proxy.scrollEdgeAppearance = appearance
        proxy.compactScrollEdgeAppearance = appearance
    }
    #else
    private static func installTransparentNavigationBarAppearance() {}
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.connectionStore)
                .environment(environment.sessionStore)
                .environment(environment.chatStore)
                .environment(environment.attachmentStore)
                .environment(environment.queueStore)
                .environment(environment.voiceRecorder)
                .environment(environment.speechPlayer)
                .environment(environment.inboxStore)
                .environment(environment.appLock)
                .environment(environment.themeStore)
                // The deep-link pair-confirmation coordinator (L11). Owned at the
                // app root, observed by RootView to present the destructive-repair
                // confirmation. Not part of AppEnvironment — it is a view-layer
                // concern with no store dependencies.
                .environment(deepLink)
                // Install the resolved palette (\.hermesTheme), the global brand
                // tint, and the forced color scheme at the app root in one shot.
                // Sheet/NavigationStack roots must re-apply `.hermesThemed(store)`
                // because SwiftUI does not reliably inherit custom environment
                // values across presentation boundaries.
                .hermesThemed(environment.themeStore)
                .overlay(alignment: .top) {
                    if let sharedInboxToast {
                        AppToastBanner(message: sharedInboxToast)
                            .padding(.top, 16)
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: sharedInboxToast)
                .task {
                    #if DEBUG
                    // DEBUG-only main-thread hitch logger (HERMES_PERF_LOG=1). Cheap,
                    // allocation-free in steady state; durable measurement tooling.
                    // Started FIRST so it captures the seed/stream window too.
                    if PerfHitchLogger.isEnabled {
                        PerfHitchLogger.shared.start()
                    }
                    // DEBUG-only deterministic seed: when HERMES_UITEST_SEED is set,
                    // bypass the network bootstrap AND the debug overlay/badge so
                    // seeded captures (demo footage) are clean.
                    if let seed = UITestSeed.requestedMode {
                        UITestSeed.apply(seed, environment: environment)
                        // MEASUREMENT MODE: when BOTH the seed AND the debug bridge are
                        // requested (HERMES_DEBUG_BRIDGE=1), start the bridge anyway so a
                        // harness can drive scrolls (/swipe → setContentOffset) against
                        // the seeded transcript. The on-device badge/overlay is fine
                        // during measurement (it is not a demo capture). Clean seeded
                        // captures simply omit HERMES_DEBUG_BRIDGE.
                        if ProcessInfo.processInfo.environment["HERMES_DEBUG_BRIDGE"] == "1" {
                            startGstackDebugBridge(environment: environment)
                        }
                        return
                    }
                    // gstack debug bridge (task UI-G): loopback-only StateServer
                    // + typed store accessors. DEBUG-only; absent in Release.
                    startGstackDebugBridge(environment: environment)
                    #endif
                    environment.appLock.authenticateAtLaunch()
                    // Route notification taps (local + remote APNs) into the store
                    // graph. Registered before bootstrap so a cold-launch tap —
                    // which iOS delivers right after launch — is honored once the
                    // session list is refreshed inside the router.
                    NotificationService.setTapHandler { tap in
                        HermesURLRouter.routePushTap(
                            tap,
                            sessions: environment.sessionStore,
                            inbox: environment.inboxStore
                        )
                    }
                    // Wire the notification-action backend (A2): APPROVE / DENY on
                    // a HERMES_APPROVAL push resolves against the gateway via this
                    // resolved endpoint (same loopback URL + Keychain token as the
                    // push registrar). `nil` when unconfigured → the action falls
                    // back to a feedback notification.
                    NotificationService.setActionEndpointProvider {
                        PushRegistrar.shared.resolveEndpoint().map {
                            NotificationService.ActionEndpoint(
                                baseURL: $0.url, token: $0.token, pathStyle: $0.pathStyle
                            )
                        }
                    }
                    await environment.connectionStore.bootstrap()
                    #if DEBUG
                    // Inc-3b UITest seam: HERMES_UITEST_DEEPLINK fires a deep link
                    // immediately after bootstrap, exactly as if onOpenURL had been
                    // called with that URL. Allows the UITest harness to trigger deep
                    // links (including manual_token pair payloads) from the test
                    // runner without relying on xcrun simctl (not available inside
                    // the iOS test runner process). Gated on DEBUG so it is never
                    // compiled into Release.
                    if let deepLinkStr = ProcessInfo.processInfo.environment["HERMES_UITEST_DEEPLINK"],
                       !deepLinkStr.isEmpty,
                       let deepLinkURL = URL(string: deepLinkStr) {
                        HermesURLRouter.route(
                            deepLinkURL,
                            connection: environment.connectionStore,
                            sessions: environment.sessionStore,
                            chat: environment.chatStore,
                            inbox: environment.inboxStore,
                            requestPairConfirmation: { payload in
                                deepLink.requestPairConfirmation(payload)
                            },
                            requestManualTokenPair: { payload in
                                deepLink.requestManualTokenPair(payload)
                            }
                        )
                    }
                    #endif
                    // Push is opt-in; this no-ops unless the user enabled it.
                    PushRegistrar.shared.enableIfAllowed()
                    // First-launch usage figures for the widgets, once connected.
                    environment.refreshUsageSnapshot()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    environment.connectionStore.handleScenePhase(newPhase)
                    environment.appLock.handleScenePhase(newPhase)
                    // UX1: start/stop the 30-second foreground heartbeat so the
                    // session list refreshes without user interaction in the foreground.
                    environment.sessionStore.handleScenePhaseActive(newPhase == .active)
                    // On foreground: apply parked App Intents, drain the share
                    // inbox, and refresh the widgets' usage figures.
                    if newPhase == .active {
                        PendingIntentRouter.drain(
                            connection: environment.connectionStore,
                            sessions: environment.sessionStore,
                            chat: environment.chatStore
                        )
                        SharedInboxDrainer.drain(
                            connection: environment.connectionStore,
                            sessions: environment.sessionStore,
                            chat: environment.chatStore,
                            attachments: environment.attachmentStore,
                            onDrained: { count in
                                presentSharedInboxToast(processed: count)
                            }
                        )
                        environment.refreshUsageSnapshot()
                    }
                }
                .onOpenURL { url in
                    HermesURLRouter.route(
                        url,
                        connection: environment.connectionStore,
                        sessions: environment.sessionStore,
                        chat: environment.chatStore,
                        inbox: environment.inboxStore,
                        // Re-pairing over a live/saved connection is destructive;
                        // stash the payload and let RootView confirm before the
                        // disconnect-and-repair (an unconfigured app pairs directly
                        // inside `route`, never reaching this seam).
                        requestPairConfirmation: { payload in
                            deepLink.requestPairConfirmation(payload)
                        },
                        // Inc-3b: Local-desktop pairing when the token cannot be
                        // recovered by the plugin (manual_token=true). Stash the
                        // payload and let ManualTokenPromptView ask the user.
                        requestManualTokenPair: { payload in
                            deepLink.requestManualTokenPair(payload)
                        }
                    )
                }
                // P0 SPOTLIGHT / HANDOFF RECEIVER (L11): SpotlightIndexer mints
                // both the open-session Handoff activity AND Spotlight items, and
                // Info.plist registers the activity type — but nothing received the
                // continuation, so Handoff arrivals and Spotlight taps no-oped.
                // Receive BOTH the open-session activity (Handoff from a peer / the
                // app's own advertised activity) AND CSSearchableItemActionType (a
                // tapped Spotlight result) here at the scene root, routing each to
                // the same stored-id resolution (+ inbox fallback) as the
                // `session/<id>` deep link. iOS replays the launch activity right
                // after the scene connects, so a cold-launch tap is honored once
                // the router's refresh resolves the (possibly empty) list.
                .onContinueUserActivity(SpotlightIndexer.openSessionActivityType) { activity in
                    HermesURLRouter.routeContinuedActivity(
                        activity,
                        sessions: environment.sessionStore,
                        inbox: environment.inboxStore
                    )
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    HermesURLRouter.routeContinuedActivity(
                        activity,
                        sessions: environment.sessionStore,
                        inbox: environment.inboxStore
                    )
                }
        }
    }

    @MainActor
    private func presentSharedInboxToast(processed count: Int) {
        guard count > 0 else { return }
        sharedInboxToastDismissTask?.cancel()
        sharedInboxToast = "Queued \(count) shared item(s)"
        sharedInboxToastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            sharedInboxToast = nil
            sharedInboxToastDismissTask = nil
        }
    }
}

private struct AppToastBanner: View {
    let message: String
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.bg)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(theme.fg.opacity(0.9), in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .accessibilityLabel(message)
    }
}

#if canImport(UIKit)
/// App delegate adaptor whose sole job is forwarding the APNs device-token
/// callbacks (which only fire on a `UIApplicationDelegate`) to ``PushRegistrar``.
/// `PushRegistrar` is `@MainActor`; these UIKit callbacks land on the main
/// thread, so `MainActor.assumeIsolated` is safe and avoids a hop.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated {
            PushRegistrar.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        MainActor.assumeIsolated {
            PushRegistrar.shared.didFailToRegister(error: error)
        }
    }
}
#endif
