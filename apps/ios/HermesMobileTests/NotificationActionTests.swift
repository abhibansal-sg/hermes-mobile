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
