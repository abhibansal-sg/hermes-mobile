import XCTest
@testable import HermesMobile

/// ABH-84 follow-up: model visibility curation + provider-aware selection
/// identity. Ports the desktop `model-visibility.ts` semantics and pins the
/// build-22 dual-checkmark bug (same model name on two providers both showed
/// selected) shut at the logic level.
final class ModelVisibilityTests: XCTestCase {

    private func provider(_ slug: String, models: [String], isCurrent: Bool = false) -> ModelProvider {
        ModelProvider(json: .object([
            "slug": .string(slug),
            "name": .string(slug.capitalized),
            "is_current": .bool(isCurrent),
            "models": .array(models.map { .string($0) }),
        ]))
    }

    // MARK: - Family collapse (desktop collapseModelFamilies parity)

    func testFamilyCollapseMergesFastSibling() {
        let families = ModelVisibility.collapseModelFamilies(["gpt-5.5", "gpt-5.5-fast", "o9-mini"])
        XCTAssertEqual(families, [
            ModelFamily(id: "gpt-5.5", fastId: "gpt-5.5-fast"),
            ModelFamily(id: "o9-mini", fastId: nil),
        ])
    }

    func testFamilyCollapsePreservesOrderByBasePosition() {
        // The fast variant precedes its base in the wire list — the family
        // row still sits at the BASE model's position.
        let families = ModelVisibility.collapseModelFamilies(["a-fast", "b", "a"])
        XCTAssertEqual(families, [
            ModelFamily(id: "b", fastId: nil),
            ModelFamily(id: "a", fastId: "a-fast"),
        ])
    }

    func testFastOnlyModelStandsAlone() {
        // A `…-fast` model with no base present is its own family.
        let families = ModelVisibility.collapseModelFamilies(["solo-fast"])
        XCTAssertEqual(families, [ModelFamily(id: "solo-fast", fastId: nil)])
    }

    func testFamilyCollapseIsCaseInsensitiveOnFastSuffix() {
        let families = ModelVisibility.collapseModelFamilies(["m", "m-FAST"])
        XCTAssertEqual(families.count, 1)
        XCTAssertEqual(families[0].id, "m")
        XCTAssertEqual(families[0].fastId, "m-FAST")
    }

    // MARK: - Visibility keys

    func testKeyFormatSeparatesProviderAndModel() {
        XCTAssertEqual(ModelVisibility.key(provider: "openai", model: "gpt-5.5"), "openai::gpt-5.5")
        // `::` keeps single-colon model ids unambiguous.
        XCTAssertNotEqual(
            ModelVisibility.key(provider: "a", model: "b:c"),
            ModelVisibility.key(provider: "a:b", model: "c")
        )
    }

    func testDefaultVisibleKeysCapsPerProviderFamilies() {
        let many = (0..<60).map { "model-\($0)" }
        let keys = ModelVisibility.defaultVisibleKeys(providers: [provider("p", models: many)])
        XCTAssertEqual(keys.count, ModelVisibility.defaultVisiblePerProvider)
        XCTAssertTrue(keys.contains("p::model-0"))
        XCTAssertFalse(keys.contains("p::model-59"))
    }

    func testEffectiveVisibleKeysPrefersStoredSet() {
        let providers = [provider("p", models: ["m1", "m2"])]
        let stored: Set<String> = ["p::m2"]
        XCTAssertEqual(ModelVisibility.effectiveVisibleKeys(stored: stored, providers: providers), stored)
        XCTAssertEqual(
            ModelVisibility.effectiveVisibleKeys(stored: nil, providers: providers),
            ["p::m1", "p::m2"]
        )
    }

    // MARK: - Persistence round-trip

    func testPersistenceRoundTripAndReset() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "ModelVisibilityTests"))
        suite.removePersistentDomain(forName: "ModelVisibilityTests")
        defer { suite.removePersistentDomain(forName: "ModelVisibilityTests") }

        XCTAssertNil(ModelVisibility.load(defaults: suite))
        let keys: Set<String> = ["openai::gpt-5.5", "github::gpt-5.5"]
        ModelVisibility.save(keys, defaults: suite)
        XCTAssertEqual(ModelVisibility.load(defaults: suite), keys)
        ModelVisibility.save(nil, defaults: suite)   // Reset → default applies.
        XCTAssertNil(ModelVisibility.load(defaults: suite))
    }

    // MARK: - Selection identity (the build-22 dual-checkmark bug)

    func testSameModelNameOnTwoProvidersSelectsOnlyTheCurrentProvider() {
        let families = ModelVisibility.collapseModelFamilies(["gpt-5.5", "other"])
        // Current = openai's gpt-5.5. The github section must NOT highlight
        // its same-named row.
        XCTAssertEqual(
            ModelVisibility.currentFamilyId(
                providerSlug: "openai", currentProvider: "openai",
                currentModel: "gpt-5.5", families: families
            ),
            "gpt-5.5"
        )
        XCTAssertNil(
            ModelVisibility.currentFamilyId(
                providerSlug: "github", currentProvider: "openai",
                currentModel: "gpt-5.5", families: families
            )
        )
    }

    func testCurrentFastVariantHighlightsItsBaseFamily() {
        let families = ModelVisibility.collapseModelFamilies(["gpt-5.5", "gpt-5.5-fast"])
        XCTAssertEqual(
            ModelVisibility.currentFamilyId(
                providerSlug: "openai", currentProvider: "openai",
                currentModel: "gpt-5.5-fast", families: families
            ),
            "gpt-5.5"
        )
    }

    func testEmptyCurrentModelMatchesNothing() {
        let families = ModelVisibility.collapseModelFamilies(["m"])
        XCTAssertNil(
            ModelVisibility.currentFamilyId(
                providerSlug: "p", currentProvider: "p",
                currentModel: "", families: families
            )
        )
    }

    // MARK: - session.info raw/provider decode (ConnectionStore)

    @MainActor
    func testApplySessionInfoTracksRawModelAndProvider() {
        let store = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
        store.applySessionInfo(.object([
            "model": .string("gpt-5.5-2025-11-20"),
            "provider": .string("openai"),
        ]))
        XCTAssertEqual(store.sessionModelRaw, "gpt-5.5-2025-11-20")
        XCTAssertEqual(store.sessionProvider, "openai")
        // The chip-facing name stays shortened; raw is for row identity.
        XCTAssertEqual(store.sessionModel, "gpt-5.5")

        // Older gateways without the provider field must not clear it.
        store.applySessionInfo(.object(["model": .string("o9")]))
        XCTAssertEqual(store.sessionProvider, "openai")
        XCTAssertEqual(store.sessionModelRaw, "o9")

        store.clearSessionState()
        XCTAssertNil(store.sessionModelRaw)
        XCTAssertNil(store.sessionProvider)
    }

    // MARK: - Draft-mode model pick (pick at any point, ABH-84 follow-up)

    @MainActor
    func testDraftSelectionPendsAndClears() {
        let store = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
        store.draftSelection = DraftModelSelection(
            model: "gpt-5.5-2025-11-20", provider: "openai", reasoningEffort: "high", fast: true
        )
        // The chip shows the pended pick, shortened like any model name.
        XCTAssertEqual(store.draftModelShortName, "gpt-5.5")

        // Opening an existing chat / fresh draft drops the pend.
        store.clearDraftSelection()
        XCTAssertNil(store.draftSelection)
        XCTAssertNil(store.draftModelShortName)

        // Connection teardown clears it too.
        store.draftSelection = DraftModelSelection(model: "m", provider: "p", reasoningEffort: nil, fast: nil)
        store.clearSessionState()
        XCTAssertNil(store.draftSelection)
    }

    @MainActor
    func testApplyDraftSelectionIsBestEffortAndOneShot() async {
        let store = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
        // No connected client: every config.set throws — apply must swallow
        // (the first message must never be blocked) and still clear the pend.
        store.draftSelection = DraftModelSelection(model: "m", provider: "p", reasoningEffort: "low", fast: false)
        await store.applyDraftSelection(sessionId: "s1")
        XCTAssertNil(store.draftSelection, "apply is one-shot — pend cleared even on failure")

        // No pend → no-op.
        await store.applyDraftSelection(sessionId: "s1")
        XCTAssertNil(store.draftSelection)
    }

    @MainActor
    func testApplyRuntimeInfoSeedsPillFromResumeEcho() {
        // Build-27 QA: the pill kept showing the PREVIOUS session's model on
        // switch. The resume echo carries the session's actual state — apply
        // must seed all four fields (and shorten the chip name).
        let store = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
        store.applyRuntimeInfo(SessionRuntimeInfo(
            model: "gpt-5.5-2025-11-20", provider: "openai", running: nil, cwd: nil,
            lazy: nil, profileName: nil, reasoningEffort: "high", fast: true, serviceTier: "priority"
        ))
        XCTAssertEqual(store.sessionModelRaw, "gpt-5.5-2025-11-20")
        XCTAssertEqual(store.sessionModel, "gpt-5.5")
        XCTAssertEqual(store.sessionProvider, "openai")
        XCTAssertEqual(store.sessionReasoningEffort, "high")
        XCTAssertEqual(store.sessionFast, true)

        // Empty/nil fields must not clobber (a lazy resume echoes no model).
        store.applyRuntimeInfo(SessionRuntimeInfo(
            model: "", provider: nil, running: nil, cwd: nil,
            lazy: true, profileName: nil, reasoningEffort: nil, fast: nil, serviceTier: nil
        ))
        XCTAssertEqual(store.sessionModelRaw, "gpt-5.5-2025-11-20")
        XCTAssertEqual(store.sessionProvider, "openai")
    }

    @MainActor
    func testOpenClearsPreviousSessionPillState() {
        // The switch itself must drop the old session's hot-swap state so the
        // pill never shows the LAST chat's model while the resume is in
        // flight (build-27 QA symptom).
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)

        connection.applySessionInfo(.object(["model": .string("prev-model"), "provider": .string("p")]))
        let summary = SessionSummary(
            id: "s2", title: "Other chat", preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
        sessions.open(summary)
        XCTAssertNil(connection.sessionModel)
        XCTAssertNil(connection.sessionModelRaw)
        XCTAssertNil(connection.sessionProvider)
    }

    @MainActor
    func testStartDraftClearsStaleSessionStateAndPick() {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)

        // Simulate a previous session's hot-swap state + a stale pick.
        connection.applySessionInfo(.object(["model": .string("old-model"), "provider": .string("old")]))
        connection.draftSelection = DraftModelSelection(model: "m", provider: "p", reasoningEffort: nil, fast: nil)

        sessions.startDraft()

        // A draft has no session: the pill must not show the LAST chat's model.
        XCTAssertNil(connection.sessionModel)
        XCTAssertNil(connection.sessionModelRaw)
        XCTAssertNil(connection.sessionProvider)
        XCTAssertNil(connection.draftSelection)
        XCTAssertTrue(sessions.isDraft)
    }
}
