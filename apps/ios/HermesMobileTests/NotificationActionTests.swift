import XCTest
@testable import HermesMobile

/// Coverage for the F2-A actionable-push surfaces:
///  - push-payload decoding (category routing + the `hermes` block, incl.
///    `destructive` / `stored_session_id` / `approval_title`),
///  - the action-identifier → approve/deny mapping,
///  - the per-event push-prefs round-trip through `DefaultsKeys`.
///
/// These exercise the pure, host-runnable transforms. The network legs
/// (`/api/approvals/respond`, `/api/push/live-activity`) and the LAContext gate
/// are status-code / system-prompt driven and are validated by the integration
/// gate (live dashboard on 9123); see CONTRACT-F2.md.
final class NotificationActionTests: XCTestCase {

    // MARK: - aps.category decode

    func testApsCategoryReadsNestedApsBlock() {
        let userInfo: [AnyHashable: Any] = ["aps": ["category": "HERMES_APPROVAL"]]
        XCTAssertEqual(NotificationService.apsCategory(in: userInfo), "HERMES_APPROVAL")
    }

    func testApsCategoryNilWhenAbsent() {
        XCTAssertNil(NotificationService.apsCategory(in: ["aps": ["alert": "hi"]]))
        XCTAssertNil(NotificationService.apsCategory(in: [:]))
    }

    // MARK: - decodeTap via aps.category (no event_type)

    func testDecodeTapRoutesApprovalCategoryToAttention() {
        // The F2-S remote payload routes by `aps.category` (no flat event_type).
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_APPROVAL"],
            "hermes": ["session_id": "sess-runtime-1"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .attention(sessionId: "sess-runtime-1")
        )
    }

    func testDecodeTapRoutesClarifyCategoryToAttention() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_CLARIFY"],
            "hermes": ["session_id": "sess-2"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .attention(sessionId: "sess-2")
        )
    }

    func testDecodeTapRoutesTurnCategoryToTurnComplete() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_TURN"],
            "hermes": ["session_id": "sess-3"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .turnComplete(sessionId: "sess-3")
        )
    }

    func testDecodeTapStillHonorsExplicitEventType() {
        // A flat event_type (local notifications / legacy) takes precedence over
        // category and keeps working.
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_TURN"],
            "hermes": ["session_id": "sess-4", "event_type": "approval"],
        ]
        XCTAssertEqual(
            NotificationService.decodeTap(from: userInfo),
            .attention(sessionId: "sess-4")
        )
    }

    func testDecodeTapNilWithoutSessionId() {
        let userInfo: [AnyHashable: Any] = ["aps": ["category": "HERMES_APPROVAL"]]
        XCTAssertNil(NotificationService.decodeTap(from: userInfo))
    }

    // MARK: - decodeApprovalAction (the hermes block)

    func testDecodeApprovalActionFullBlock() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "HERMES_APPROVAL"],
            "hermes": [
                "session_id": "sess-runtime",
                "stored_session_id": "sess-stored",
                "destructive": true,
                "approval_title": "rm -rf build/",
            ],
        ]
        let action = try XCTUnwrap(NotificationService.decodeApprovalAction(from: userInfo))
        XCTAssertEqual(action.sessionId, "sess-runtime")
        XCTAssertEqual(action.storedSessionId, "sess-stored")
        XCTAssertTrue(action.destructive)
        XCTAssertEqual(action.approvalTitle, "rm -rf build/")
    }

    func testDecodeApprovalActionDefaultsDestructiveFalse() throws {
        let userInfo: [AnyHashable: Any] = [
            "hermes": ["session_id": "sess-x"],
        ]
        let action = try XCTUnwrap(NotificationService.decodeApprovalAction(from: userInfo))
        XCTAssertEqual(action.sessionId, "sess-x")
        XCTAssertNil(action.storedSessionId)
        XCTAssertFalse(action.destructive, "destructive must default to false when absent")
        XCTAssertNil(action.approvalTitle)
    }

    func testDecodeApprovalActionToleratesStringifiedDestructive() throws {
        // Some APNs JSON paths stringify booleans; "true"/"1" must still gate.
        for raw in ["true", "1", "yes", "TRUE"] {
            let userInfo: [AnyHashable: Any] = [
                "hermes": ["session_id": "s", "destructive": raw],
            ]
            let action = try XCTUnwrap(NotificationService.decodeApprovalAction(from: userInfo))
            XCTAssertTrue(action.destructive, "expected destructive for \(raw)")
        }
        // And a stringy false stays false.
        let falsey: [AnyHashable: Any] = ["hermes": ["session_id": "s", "destructive": "false"]]
        let action = try XCTUnwrap(NotificationService.decodeApprovalAction(from: falsey))
        XCTAssertFalse(action.destructive)
    }

    func testDecodeApprovalActionNilWithoutHermesBlock() {
        XCTAssertNil(NotificationService.decodeApprovalAction(from: ["aps": ["alert": "x"]]))
    }

    func testDecodeApprovalActionNilWithEmptySessionId() {
        let userInfo: [AnyHashable: Any] = ["hermes": ["session_id": "   "]]
        XCTAssertNil(NotificationService.decodeApprovalAction(from: userInfo))
    }

    func testDecodeApprovalActionBlankStoredAndTitleBecomeNil() throws {
        let userInfo: [AnyHashable: Any] = [
            "hermes": ["session_id": "s", "stored_session_id": "  ", "approval_title": ""],
        ]
        let action = try XCTUnwrap(NotificationService.decodeApprovalAction(from: userInfo))
        XCTAssertNil(action.storedSessionId)
        XCTAssertNil(action.approvalTitle)
    }

    // MARK: - action identifier → choice mapping

    func testApproveChoiceMapping() {
        XCTAssertEqual(NotificationService.approveChoice(for: "APPROVE"), true)
        XCTAssertEqual(NotificationService.approveChoice(for: "DENY"), false)
        XCTAssertNil(NotificationService.approveChoice(for: "com.apple.UNNotificationDefaultActionIdentifier"))
        XCTAssertNil(NotificationService.approveChoice(for: "approve")) // case-sensitive: only the registered id
        XCTAssertNil(NotificationService.approveChoice(for: ""))
    }

    func testActionIdentifiersMatchCategoryContract() {
        // The action ids are part of the pinned interface; pin them in a test so
        // a rename can't silently break the server-stamped category.
        XCTAssertEqual(NotificationService.approveActionIdentifier, "APPROVE")
        XCTAssertEqual(NotificationService.denyActionIdentifier, "DENY")
        XCTAssertEqual(NotificationService.remoteApprovalCategory, "HERMES_APPROVAL")
        XCTAssertEqual(NotificationService.remoteClarifyCategory, "HERMES_CLARIFY")
        XCTAssertEqual(NotificationService.remoteTurnCategory, "HERMES_TURN")
    }
}

// MARK: - Per-event push prefs round-trip (A4)

/// Round-trips the three notification toggles through `DefaultsKeys`, asserting
/// the default-ON semantics and the deterministic wire `events` list.
final class PushEventPrefsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "PushEventPrefsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAbsentKeysDefaultOn() {
        // Fresh install / legacy: everything on, list carries all three tokens.
        XCTAssertTrue(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventApproval, defaults))
        XCTAssertTrue(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventClarify, defaults))
        XCTAssertTrue(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventTurnComplete, defaults))
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["approval", "clarify", "turn_complete"]
        )
    }

    func testTogglingApprovalOffExcludesItFromList() {
        defaults.set(false, forKey: DefaultsKeys.pushEventApproval)
        XCTAssertFalse(DefaultsKeys.pushEventEnabled(DefaultsKeys.pushEventApproval, defaults))
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["clarify", "turn_complete"],
            "approval must drop out of the events list when toggled off"
        )
    }

    func testAllOffYieldsEmptyList() {
        defaults.set(false, forKey: DefaultsKeys.pushEventApproval)
        defaults.set(false, forKey: DefaultsKeys.pushEventClarify)
        defaults.set(false, forKey: DefaultsKeys.pushEventTurnComplete)
        XCTAssertEqual(DefaultsKeys.pushEventList(defaults), [])
    }

    func testRoundTripPersistsExplicitTrue() {
        // An explicit ON (the user toggled off then on again) is honored verbatim.
        defaults.set(false, forKey: DefaultsKeys.pushEventClarify)
        XCTAssertEqual(DefaultsKeys.pushEventList(defaults), ["approval", "turn_complete"])
        defaults.set(true, forKey: DefaultsKeys.pushEventClarify)
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["approval", "clarify", "turn_complete"]
        )
    }

    func testListOrderIsStable() {
        // Order is part of the contract for deterministic access-log assertions.
        defaults.set(true, forKey: DefaultsKeys.pushEventTurnComplete)
        defaults.set(true, forKey: DefaultsKeys.pushEventApproval)
        defaults.set(true, forKey: DefaultsKeys.pushEventClarify)
        XCTAssertEqual(
            DefaultsKeys.pushEventList(defaults),
            ["approval", "clarify", "turn_complete"]
        )
    }
}

// MARK: - Push-token registration dedupe: env key (ABH-182 Inc-2)

/// Verifies that the `pushLastEnv` key is part of the registration dedupe key,
/// so a sandbox→production flip forces a re-POST even when the token and event
/// prefs are identical. Tests are pure and deterministic: they exercise the
/// `DefaultsKeys.pushLastEnv` round-trip and the 3-way guard condition that
/// `PushRegistrar.didRegister` evaluates against `UserDefaults`. No network or
/// device needed.
///
/// The guard condition (simplified):
///   savedToken == token && savedEvents == events && savedEnv == env → SKIP
///   any mismatch → RE-POST
final class PushRegistrarEnvDedupeTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "PushRegistrarEnvDedupeTests"

    // Mirrors the 3-way dedupe guard in `PushRegistrar.didRegister` so tests can
    // evaluate it against a controlled `UserDefaults` suite without touching
    // `UserDefaults.standard` or the network.
    private func wouldSkip(
        token hex: String,
        events: [String],
        env: String,
        defaults: UserDefaults
    ) -> Bool {
        defaults.string(forKey: DefaultsKeys.pushLastDeviceToken) == hex
            && defaults.stringArray(forKey: DefaultsKeys.pushLastEvents) == events
            && defaults.string(forKey: DefaultsKeys.pushLastEnv) == env
    }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - pushLastEnv round-trip

    func testEnvKeyRoundTrips() {
        // Absent → nil (never registered).
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushLastEnv))

        // Written → readable.
        defaults.set("sandbox", forKey: DefaultsKeys.pushLastEnv)
        XCTAssertEqual(defaults.string(forKey: DefaultsKeys.pushLastEnv), "sandbox")

        // Overwrite.
        defaults.set("production", forKey: DefaultsKeys.pushLastEnv)
        XCTAssertEqual(defaults.string(forKey: DefaultsKeys.pushLastEnv), "production")

        // Cleared → nil.
        defaults.removeObject(forKey: DefaultsKeys.pushLastEnv)
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushLastEnv))
    }

    // MARK: - env missing → always a dedupe miss

    func testEnvKeyAbsentCausesDedupeMiss() {
        // Simulate the state written by a pre-ABH-182 install: token + events
        // persisted, but `pushLastEnv` never written. The guard must miss so
        // the next `didRegister` re-POSTs and stamps the env.
        let token = "aabbcc"
        let events = ["approval", "clarify", "turn_complete"]
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        // pushLastEnv intentionally absent.

        XCTAssertFalse(
            wouldSkip(token: token, events: events, env: "production", defaults: defaults),
            "missing env key must NOT skip — legacy installs must re-POST once to stamp the env"
        )
    }

    // MARK: - env change → dedupe miss (the core bug fix)

    func testEnvChangeForcesRePost() {
        // Same token + events that were registered under sandbox. Now the env
        // flipped to production (Xcode → TestFlight on the same device). The
        // dedupe must miss so the gateway receives a re-registration with the
        // correct env.
        let token = "deadbeef"
        let events = ["approval", "turn_complete"]
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        defaults.set("sandbox", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertFalse(
            wouldSkip(token: token, events: events, env: "production", defaults: defaults),
            "env sandbox→production must be a dedupe miss even when token+events are identical"
        )
    }

    func testReverseEnvChangeForcesRePost() {
        // Symmetric: production → sandbox (e.g. side-loading a dev build after
        // a TestFlight install). The dedupe must still miss.
        let token = "cafebabe"
        let events: [String] = []
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        defaults.set("production", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertFalse(
            wouldSkip(token: token, events: events, env: "sandbox", defaults: defaults),
            "env production→sandbox must be a dedupe miss"
        )
    }

    // MARK: - all three unchanged → dedupe hit

    func testIdenticalTokenEventsEnvSkips() {
        // All three fields match: the gateway already has the correct
        // registration → skip the redundant POST.
        let token = "112233"
        let events = ["approval", "clarify", "turn_complete"]
        let env = "production"
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        defaults.set(env, forKey: DefaultsKeys.pushLastEnv)

        XCTAssertTrue(
            wouldSkip(token: token, events: events, env: env, defaults: defaults),
            "identical token+events+env must skip the POST"
        )
    }

    func testIdenticalStateSandboxSkips() {
        // Sandbox variant: simulator / Xcode dev builds must also dedupe when
        // token+events+env are all unchanged.
        let token = "00ff00"
        let events = ["clarify"]
        defaults.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(events, forKey: DefaultsKeys.pushLastEvents)
        defaults.set("sandbox", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertTrue(
            wouldSkip(token: token, events: events, env: "sandbox", defaults: defaults),
            "identical sandbox registration must skip"
        )
    }

    // MARK: - token or events change still misses (existing behaviour preserved)

    func testTokenChangeMissesRegardlessOfEnv() {
        defaults.set("aaa", forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(["approval"], forKey: DefaultsKeys.pushLastEvents)
        defaults.set("production", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertFalse(
            wouldSkip(token: "bbb", events: ["approval"], env: "production", defaults: defaults),
            "different token must be a miss even when events+env match"
        )
    }

    func testEventsChangeMissesRegardlessOfEnv() {
        defaults.set("aaa", forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(["approval"], forKey: DefaultsKeys.pushLastEvents)
        defaults.set("production", forKey: DefaultsKeys.pushLastEnv)

        XCTAssertFalse(
            wouldSkip(token: "aaa", events: ["approval", "clarify"], env: "production", defaults: defaults),
            "different events must be a miss even when token+env match"
        )
    }
}

// MARK: - Approval respond outcome shape

/// Pins the `RestClient.ApprovalRespondOutcome` cases the action handler branches
/// on, so a refactor can't silently drop the "already handled" feedback path.
final class ApprovalRespondOutcomeTests: XCTestCase {
    func testOutcomeCasesAreDistinct() {
        XCTAssertNotEqual(RestClient.ApprovalRespondOutcome.resolved, .alreadyHandled)
        XCTAssertNotEqual(RestClient.ApprovalRespondOutcome.resolved, .failed)
        XCTAssertNotEqual(RestClient.ApprovalRespondOutcome.alreadyHandled, .failed)
    }

    func testLiveActivityOutcomeCasesAreDistinct() {
        XCTAssertNotEqual(RestClient.LiveActivityTokenOutcome.success, .notDeployed)
        XCTAssertNotEqual(RestClient.LiveActivityTokenOutcome.success, .failed)
        XCTAssertNotEqual(RestClient.LiveActivityTokenOutcome.notDeployed, .failed)
    }
}
