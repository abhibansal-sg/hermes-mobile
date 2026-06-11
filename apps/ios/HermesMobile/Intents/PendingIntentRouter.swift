import Foundation

/// Applies a parked ``PendingIntent`` against the live store graph.
///
/// This is the app-side half of the App Intents handoff. The intent ran in its
/// own context, parked a request in `UserDefaults`, and foregrounded the app;
/// the app then calls ``drain(connection:sessions:chat:)`` once the scene is
/// active. Keeping the apply logic here (rather than in `HermesMobileApp`) means
/// the App Intents module owns its whole contract end to end, and the wiring in
/// `HermesMobileApp` is a single call.
///
/// All work is `@MainActor`: it drives the same `@Observable` stores the UI
/// binds to, so the navigation/transcript changes are observed immediately.
@MainActor
enum PendingIntentRouter {

    /// Take whatever request is parked and apply it, if any.
    ///
    /// Idempotent across foregrounds: the request is *removed* from `UserDefaults`
    /// as it is read, so a second `scenePhase == .active` with nothing newly
    /// parked is a no-op. Safe to call before the connection is ready — `.ask`
    /// needs a live gateway (to create + send), so it is re-parked until connect;
    /// `.newSession` (local draft) and `.openSessions` (pure navigation) need no
    /// connection and always succeed.
    ///
    /// - Parameters:
    ///   - connection: the connection store, used to gate on connectivity.
    ///   - sessions: the session store (create/activate).
    ///   - chat: the chat store (send the prompt once a session is live).
    ///   - defaults: the backing store, injectable for tests.
    static func drain(
        connection: ConnectionStore,
        sessions: SessionStore,
        chat: ChatStore,
        defaults: UserDefaults = .standard
    ) {
        guard let intent = PendingIntent.takePending(from: defaults) else { return }
        apply(intent, connection: connection, sessions: sessions, chat: chat, defaults: defaults)
    }

    /// Apply a specific request. Exposed (vs. only `drain`) so a future
    /// custom-URL-scheme or Handoff path can reuse the same activation logic.
    static func apply(
        _ intent: PendingIntent,
        connection: ConnectionStore,
        sessions: SessionStore,
        chat: ChatStore,
        defaults: UserDefaults = .standard
    ) {
        switch intent {
        case .openSessions:
            // Pure navigation: drop any active session so the list takes over.
            Task { await sessions.closeActive() }

        case .newSession:
            // LOCAL-DRAFT PARITY (User decision 3): "New session" must behave like
            // the app's "New chat" and desktop Cmd+N — open a LOCAL draft, NOT an
            // eager server session. The prior `createSessionNow()` RPC'd a real
            // session immediately, orphaning an empty session every time the user
            // ran the intent/widget without sending anything. A draft creates no
            // server state (it materializes lazily on the first prompt via
            // `ChatStore.send`), so it also needs no connectivity gate and no
            // re-park — it succeeds offline and lands the user on the composer.
            sessions.startDraft()

        case .ask(let prompt):
            guard isConnected(connection) else {
                intent.park(in: defaults)
                return
            }
            Task {
                do {
                    try await sessions.createSessionNow()
                } catch {
                    // Could not create a session: re-park so we don't lose the
                    // user's prompt; they'll get it on the next good foreground.
                    intent.park(in: defaults)
                    return
                }
                // `createSessionNow()` sets `activeRuntimeId`; `send` is a no-op without it.
                await chat.send(text: prompt)
            }
        }
    }

    /// Whether the gateway is in a state where a prompt can actually be sent.
    /// `.connected` only — `.reconnecting`/`.offline`/`.needsSetup` would drop
    /// the prompt (`ChatStore.send` requires `activeRuntimeId`), so we re-park.
    private static func isConnected(_ connection: ConnectionStore) -> Bool {
        if case .connected = connection.phase { return true }
        return false
    }
}
