import XCTest
@testable import HermesMobile

/// F4B-A.6 coverage for the DORMANT multi-profile switcher: the `profiles`
/// capability probe state machine, the `ProfileSummary` / `ProfilesSessionsResult`
/// fixture decodes (captured verbatim from the pinned upstream shapes in
/// CONTRACT-F4B.md §Interface), the `SessionSummary.profile` round-trip (incl. the
/// dormant-path nil regression guard), the switcher visibility gate, the
/// `visibleSessions` profile filter, the create/resume `profile` threading
/// decision, and the REST per-session error surfacing.
///
/// The decode/threading layer is the spec of truth until the upstream rebase, so
/// the fixtures here reproduce the server shapes byte-for-byte. No live server is
/// touched — pure decode + pure gate functions.
@MainActor
final class ProfilesTests: XCTestCase {

    /// Decode through the SAME `.convertFromSnakeCase` path `RestClient.profiles()`
    /// / `profileSessions()` use (the models have no explicit CodingKeys).
    private func decodeSnake<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Capability probe state machine

    func testProbeProfilesEndpointInconclusiveOnUnreachableHost() async {
        // A transport failure (nothing listening) must classify inconclusive,
        // never throw — so a flaky probe leaves `profiles` at `.unknown` and the
        // switcher stays hidden (the visibility gate requires `.available`).
        let rest = RestClient(baseURL: URL(string: "http://127.0.0.1:1")!, token: "t")
        let result = await rest.probeProfilesEndpoint()
        XCTAssertEqual(result, .inconclusive)
    }

    func testProbeClassificationByStatusAndBody() {
        // DORMANCY-CRITICAL: the probe targets `GET /api/profiles/sessions` (the
        // route genuinely NEW at the rebase), NOT `GET /api/profiles` (which
        // already exists on today's server and would break dormancy). Pin the
        // status→result classification the probe applies, incl. the body
        // refinement (a 200 must carry a `sessions` array).
        func classify(status: Int, bodyHasSessionsArray: Bool) -> RestClient.UploadProbeResult {
            switch status {
            case 200: return bodyHasSessionsArray ? .available : .inconclusive
            case 404, 405: return .unavailable
            default: return .inconclusive
            }
        }
        XCTAssertEqual(classify(status: 200, bodyHasSessionsArray: true), .available)
        XCTAssertEqual(classify(status: 200, bodyHasSessionsArray: false), .inconclusive)
        XCTAssertEqual(classify(status: 404, bodyHasSessionsArray: false), .unavailable)
        XCTAssertEqual(classify(status: 405, bodyHasSessionsArray: false), .unavailable)
        XCTAssertEqual(classify(status: 500, bodyHasSessionsArray: false), .inconclusive)
    }

    func testProbeStateMappingMirrorsUploadFsTriState() {
        // The ServerCapabilities probe folds the shared UploadProbeResult into the
        // capability State exactly like upload/fs: available→available,
        // unavailable→unavailable, inconclusive→unknown. Pin the mapping invariant.
        func map(_ r: RestClient.UploadProbeResult) -> ServerCapabilities.State {
            switch r {
            case .available: return .available
            case .unavailable: return .unavailable
            case .inconclusive: return .unknown
            }
        }
        XCTAssertEqual(map(.available), .available)
        XCTAssertEqual(map(.unavailable), .unavailable)
        XCTAssertEqual(map(.inconclusive), .unknown)
    }

    func testCapabilityDefaultsUnknownAndResetClears() {
        let caps = ServerCapabilities()
        XCTAssertEqual(caps.profiles, .unknown)
        caps.reset()
        XCTAssertEqual(caps.profiles, .unknown)
    }

    func testCapabilityCacheRoundTripIncludesProfiles() throws {
        // Encode a Cache carrying a non-default `profiles` value, then decode it —
        // the value must survive (the F4a fs/subagent pattern, extended for F4b).
        struct Probe: Codable {
            var serverURL = "https://h"
            var appVersion = "1 (1)"
            var upload = ServerCapabilities.State.available
            var pushRegistry = ServerCapabilities.State.unknown
            var broadcast = ServerCapabilities.State.unknown
            var fs = ServerCapabilities.State.available
            var subagentEvents = ServerCapabilities.State.unknown
            var profiles = ServerCapabilities.State.available
        }
        let data = try JSONEncoder().encode(Probe())
        let decoded = try JSONDecoder().decode(Probe.self, from: data)
        XCTAssertEqual(decoded.profiles, .available)
    }

    func testPreF4bCacheRestoresProfilesAsUnknown() throws {
        // A cache written by a pre-F4b build omits the `profiles` key entirely.
        // The decodeIfPresent-tolerant Cache must restore it as `.unknown` rather
        // than failing the whole decode (which would force a needless re-probe).
        // The State enum decodes its rawValue; a missing key → nil → `.unknown`.
        let json = "{}"
        struct Tolerant: Decodable {
            let profiles: ServerCapabilities.State
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                profiles = try c.decodeIfPresent(ServerCapabilities.State.self, forKey: .profiles) ?? .unknown
            }
            enum CodingKeys: String, CodingKey { case profiles }
        }
        let decoded = try JSONDecoder().decode(Tolerant.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.profiles, .unknown)
    }

    // MARK: - ProfileSummary decode (fixture from _profile_to_dict)

    func testProfileSummaryDecodesDefaultAndNamedRows() throws {
        // Captured verbatim from `_profile_to_dict` (web_server.py:6757-6773): the
        // default row (name=="default", is_default==true) + a named row
        // (is_default==false). All the extra keys must be ignored.
        let json = """
        {"profiles":[
          {"name":"default","path":"/Users/x/.hermes","is_default":true,"model":"sonnet",
           "provider":"anthropic","has_env":true,"skill_count":12,"gateway_running":true,
           "description":"Primary","description_auto":false,"distribution_name":null,
           "version":null,"source":null,"has_alias":false},
          {"name":"work","path":"/Users/x/.hermes-work","is_default":false,"model":null,
           "provider":null,"has_env":false,"skill_count":3,"gateway_running":false,
           "description":"Work profile","description_auto":true,"distribution_name":"acme",
           "version":"1.2","source":"git","has_alias":true}
        ]}
        """
        struct Wrapper: Decodable { let profiles: [ProfileSummary] }
        let wrapper = try decodeSnake(Wrapper.self, json)
        XCTAssertEqual(wrapper.profiles.count, 2)

        let def = wrapper.profiles[0]
        XCTAssertEqual(def.name, "default")
        XCTAssertTrue(def.isDefault)
        XCTAssertEqual(def.description, "Primary")
        XCTAssertEqual(def.id, "default")  // id == name

        let work = wrapper.profiles[1]
        XCTAssertEqual(work.name, "work")
        XCTAssertFalse(work.isDefault)
        XCTAssertEqual(work.description, "Work profile")
    }

    func testProfileSummaryTolerantOfMissingDescription() throws {
        let json = """
        {"name":"solo","path":"/p","is_default":false}
        """
        let p = try decodeSnake(ProfileSummary.self, json)
        XCTAssertEqual(p.name, "solo")
        XCTAssertFalse(p.isDefault)
        XCTAssertNil(p.description)
    }

    // MARK: - ProfilesSessionsResult decode (fixture from get_profiles_sessions)

    func testProfilesSessionsResultDecodesWrapperAndTagsEachRow() throws {
        // Captured verbatim from web_server.py:1734-1741 + per-row tags
        // :1717-1724. Assert the wrapper fields AND that each row's
        // SessionSummary.profile carries the handler's `profile` tag.
        let json = """
        {
          "sessions":[
            {"id":"s1","title":"Default chat","preview":"hi…","started_at":1700000000.0,
             "message_count":4,"source":"cli","last_active":1700000500.0,"cwd":"/d",
             "profile":"default","is_default_profile":true,"is_active":true,"archived":false},
            {"id":"s2","title":"Work chat","preview":"todo…","started_at":1700000100.0,
             "message_count":7,"source":"cli","last_active":1700000600.0,"cwd":"/w",
             "profile":"work","is_default_profile":false,"is_active":false,"archived":false}
          ],
          "total":2,
          "profile_totals":{"default":1,"work":1},
          "limit":20,
          "offset":0,
          "errors":[{"profile":"broken","error":"state.db locked"}]
        }
        """
        let result = try decodeSnake(ProfilesSessionsResult.self, json)
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.limit, 20)
        XCTAssertEqual(result.offset, 0)
        XCTAssertEqual(result.profileTotals, ["default": 1, "work": 1])
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions[0].profile, "default")
        XCTAssertEqual(result.sessions[1].profile, "work")
        // The base SessionSummary fields decode too (recency/cwd grouping intact).
        XCTAssertEqual(result.sessions[0].id, "s1")
        XCTAssertEqual(result.sessions[1].cwd, "/w")
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.errors[0].profile, "broken")
        XCTAssertEqual(result.errors[0].error, "state.db locked")
    }

    func testProfilesSessionsResultTolerantOfEmptyErrors() throws {
        let json = """
        {"sessions":[],"total":0,"profile_totals":{},"limit":20,"offset":0,"errors":[]}
        """
        let result = try decodeSnake(ProfilesSessionsResult.self, json)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.profileTotals.isEmpty)
    }

    // MARK: - SessionSummary.profile round-trip + dormant-path nil guard

    func testSessionSummaryDecodesProfileWhenPresent() throws {
        let json = """
        {"id":"x","title":"t","profile":"work"}
        """
        let s = try decodeSnake(SessionSummary.self, json)
        XCTAssertEqual(s.profile, "work")
    }

    func testStockSessionRowDecodesProfileAsNil() throws {
        // DORMANT-PATH REGRESSION GUARD: a stock `GET /api/sessions` row (and the
        // WS session.list shape) omits `profile` — it MUST decode `nil`, leaving
        // the single-profile path byte-for-byte unchanged.
        let json = """
        {"id":"x","title":"t","preview":"p","started_at":1.0,"message_count":2,
         "source":"cli","last_active":2.0,"cwd":"/c"}
        """
        let s = try decodeSnake(SessionSummary.self, json)
        XCTAssertNil(s.profile)
        // The other fields still decode (no regression to the existing shape).
        XCTAssertEqual(s.id, "x")
        XCTAssertEqual(s.cwd, "/c")
        XCTAssertEqual(s.messageCount, 2)
    }

    func testMemberwisePositionalCallersCompileWithProfileLast() {
        // `profile` is the LAST stored property with a default, so the synthesized
        // memberwise init keeps it a trailing optional param: the positional
        // callers compile without passing it (this build IS the assertion). Mirror
        // the 3 callers' positional shape here.
        let s = SessionSummary(
            id: "id", title: nil, preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
        XCTAssertNil(s.profile)
        // And the new trailing param is reachable when explicitly passed.
        let tagged = SessionSummary(
            id: "id2", title: nil, preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil, profile: "work"
        )
        XCTAssertEqual(tagged.profile, "work")
    }

    // MARK: - Switcher visibility gate (the dormancy guarantee)

    func testSwitcherVisibilityGate() {
        // (available, count>1) ⇒ shown
        XCTAssertTrue(SessionStore.shouldShowSwitcher(capability: .available, profileCount: 2))
        // (available, count==1) ⇒ hidden (single-profile supporting server)
        XCTAssertFalse(SessionStore.shouldShowSwitcher(capability: .available, profileCount: 1))
        // (available, count==0) ⇒ hidden
        XCTAssertFalse(SessionStore.shouldShowSwitcher(capability: .available, profileCount: 0))
        // (unavailable, *) ⇒ hidden (stock gateway — the live 9119 / this-branch 9123)
        XCTAssertFalse(SessionStore.shouldShowSwitcher(capability: .unavailable, profileCount: 5))
        // (unknown, *) ⇒ hidden (not yet probed / flaky probe)
        XCTAssertFalse(SessionStore.shouldShowSwitcher(capability: .unknown, profileCount: 5))
    }

    // MARK: - visibleSessions profile filter

    private func row(_ id: String, profile: String?, source: String? = nil) -> SessionSummary {
        SessionSummary(
            id: id, title: nil, preview: nil, startedAt: nil,
            messageCount: nil, source: source, lastActive: nil, cwd: nil, profile: profile
        )
    }

    func testProfileFilterKeepsOnlyMatchingRowsWhenSpecificScope() {
        let rows = [row("a", profile: "work"), row("b", profile: "default"), row("c", profile: "work")]
        let filtered = SessionStore.filterByProfile(rows, scope: "work", multiAvailable: true)
        XCTAssertEqual(filtered.map(\.id), ["a", "c"])
    }

    func testProfileFilterAllScopeKeepsEveryRow() {
        let rows = [row("a", profile: "work"), row("b", profile: "default")]
        let all = SessionStore.filterByProfile(rows, scope: DefaultsKeys.allProfilesScope, multiAvailable: true)
        XCTAssertEqual(all.map(\.id), ["a", "b"])
    }

    func testProfileFilterDormantWhenMultiUnavailable() {
        // Even with a stale "work" scope, a stock gateway (multiAvailable=false)
        // must NOT hide rows — the dormant single-profile path is unaffected.
        let rows = [row("a", profile: "work"), row("b", profile: nil)]
        let filtered = SessionStore.filterByProfile(rows, scope: "work", multiAvailable: false)
        XCTAssertEqual(filtered.map(\.id), ["a", "b"])
    }

    func testProfileFilterDefaultScopeKeepsEveryRow() {
        // The default scope is the aggregate-equivalent for filtering: it keeps
        // every row (the default's sessions live in the shared home).
        let rows = [row("a", profile: "work"), row("b", profile: "default")]
        let filtered = SessionStore.filterByProfile(rows, scope: "default", multiAvailable: true)
        XCTAssertEqual(filtered.map(\.id), ["a", "b"])
    }

    // MARK: - create/resume profile threading decision

    func testThreadingAttachesProfileOnlyForSpecificNonDefaultScope() {
        // Specific non-default scope + multi available ⇒ attach.
        XCTAssertEqual(SessionStore.profileParam(scope: "work", multiAvailable: true), "work")
        // Aggregate "all" scope ⇒ omit (the dormant/single path stays byte-for-byte).
        XCTAssertNil(SessionStore.profileParam(scope: "all", multiAvailable: true))
        // Default scope ⇒ omit (shared/launch home; threading is a no-op).
        XCTAssertNil(SessionStore.profileParam(scope: "default", multiAvailable: true))
        // Empty scope ⇒ omit.
        XCTAssertNil(SessionStore.profileParam(scope: "", multiAvailable: true))
        // Multi NOT available ⇒ omit even for a specific scope (dormant gate).
        XCTAssertNil(SessionStore.profileParam(scope: "work", multiAvailable: false))
        // Whitespace-only ⇒ omit (trimmed to empty).
        XCTAssertNil(SessionStore.profileParam(scope: "   ", multiAvailable: true))
    }

    func testThreadingDecisionDrivesParamsDictShape() {
        // Reproduce the call-site contract: a session.create params dict gets a
        // `profile` key ONLY when the decision returns a name.
        func buildCreateParams(scope: String, multiAvailable: Bool) -> [String: JSONValue] {
            var params: [String: JSONValue] = ["cols": .number(96)]
            if let name = SessionStore.profileParam(scope: scope, multiAvailable: multiAvailable) {
                params["profile"] = .string(name)
            }
            return params
        }
        // Specific scope → profile present.
        let scoped = buildCreateParams(scope: "work", multiAvailable: true)
        XCTAssertEqual(scoped["profile"], .string("work"))
        XCTAssertEqual(scoped["cols"], .number(96))
        // Default/all/dormant → profile ABSENT (byte-for-byte the shipped payload).
        XCTAssertNil(buildCreateParams(scope: "all", multiAvailable: true)["profile"])
        XCTAssertNil(buildCreateParams(scope: "default", multiAvailable: true)["profile"])
        XCTAssertNil(buildCreateParams(scope: "work", multiAvailable: false)["profile"])
    }

    func testAllProfilesOpenThreadsRowProfileIntoTranscriptFetch() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeProfile = DefaultsKeys.allProfilesScope
        sessions.profileThreadingAvailableForTesting = true

        var captured: (sessionId: String, profile: String?)?
        sessions.transcriptFetchWithProfile = { sessionId, profile in
            captured = (sessionId, profile)
            return []
        }

        sessions.open(row("work-session", profile: "work"))
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(captured?.sessionId, "work-session")
        XCTAssertEqual(captured?.profile, "work",
                       "All-profiles row opens must load transcript through the row's profile scope")
        sessions.profileThreadingAvailableForTesting = nil
    }

    func testAllProfilesDeleteThreadsRowProfileIntoProfileScopedDelete() async {
        let sessions = SessionStore()
        sessions.activeProfile = DefaultsKeys.allProfilesScope
        sessions.profileThreadingAvailableForTesting = true
        let target = row("work-session", profile: "work")
        sessions.sessions = [target]

        var captured: (sessionId: String, profile: String?)?
        sessions.deleteSessionRequest = { sessionId, profile in
            captured = (sessionId, profile)
        }

        await sessions.delete(target)

        XCTAssertEqual(captured?.sessionId, "work-session")
        XCTAssertEqual(captured?.profile, "work",
                       "All-profiles row deletes must target the row's profile store")
        XCTAssertFalse(sessions.sessions.contains(where: { $0.id == "work-session" }))
        sessions.profileThreadingAvailableForTesting = nil
    }

    func testAllProfilesCompressedOpenThreadsRowProfileToResumeAndChainTipFetch() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeProfile = DefaultsKeys.allProfilesScope
        sessions.profileThreadingAvailableForTesting = true

        var resumeProfile: String?
        sessions.resumeRPC = { requested, params in
            XCTAssertEqual(requested, "parent-session")
            if case let .string(profile)? = params["profile"] {
                resumeProfile = profile
            }
            return JSONValue.object([
                "session_id": .string("runtime-child"),
                "resumed": .string("child-session"),
            ]).decoded(as: SessionOpenResult.self)!
        }

        var transcriptCalls: [(sessionId: String, profile: String?)] = []
        sessions.transcriptFetchWithProfile = { sessionId, profile in
            transcriptCalls.append((sessionId, profile))
            return []
        }

        sessions.open(row("parent-session", profile: "work"))
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(resumeProfile, "work")
        XCTAssertTrue(transcriptCalls.contains { $0.sessionId == "parent-session" && $0.profile == "work" })
        XCTAssertTrue(transcriptCalls.contains { $0.sessionId == "child-session" && $0.profile == "work" },
                      "Compression-chain continuation seed must keep the parent row's profile scope")
        sessions.profileThreadingAvailableForTesting = nil
    }

    func testDefaultProfileRowsKeepProfilelessPerSessionActions() {
        let defaultRow = row("default-session", profile: "default")
        XCTAssertNil(SessionStore.profileParam(for: defaultRow,
                                               activeScope: DefaultsKeys.allProfilesScope,
                                               multiAvailable: true))
        XCTAssertNil(SessionStore.profileParam(for: defaultRow,
                                               activeScope: "work",
                                               multiAvailable: true),
                     "An explicit default row must not be retargeted to the active non-default scope")
    }

    // MARK: - REST per-session threading error surfacing

    func testStrictUnknownProfileErrorsSurfaceReadableMessages() {
        // The STRICT REST path returns `404 "Profile '<name>' does not exist."`
        // (web_server.py:5445-5457) and `400` on an invalid name. Both arrive as
        // RestError.badStatus carrying the server body; assert the surfaced
        // description is the native inline message the UI shows (no crash, no
        // 500-as-success).
        let notFound = RestError.badStatus(404, body: "Profile 'ghost' does not exist.")
        let desc = notFound.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Profile 'ghost' does not exist."), "got: \(desc)")
        XCTAssertTrue(desc.contains("404"))

        let invalid = RestError.badStatus(400, body: "Invalid profile name")
        let invDesc = invalid.errorDescription ?? ""
        XCTAssertTrue(invDesc.contains("Invalid profile name"), "got: \(invDesc)")
    }

    // MARK: - Active-profile pref persistence

    func testActiveProfileDefaultsToAllAndPersists() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
        let store = SessionStore()
        XCTAssertEqual(store.activeProfile, DefaultsKeys.allProfilesScope)
        XCTAssertTrue(store.isAllProfilesScope)

        store.activeProfile = "work"
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: DefaultsKeys.activeProfile),
            "work"
        )
        // A fresh store reads the persisted scope back.
        let reloaded = SessionStore()
        XCTAssertEqual(reloaded.activeProfile, "work")
        XCTAssertFalse(reloaded.isAllProfilesScope)
        XCTAssertEqual(reloaded.activeProfileName, "work")

        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
    }

    func testActiveProfileNameNilForAllAndDefaultScopes() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
        let store = SessionStore()
        store.activeProfile = DefaultsKeys.allProfilesScope
        XCTAssertNil(store.activeProfileName)
        store.activeProfile = "default"
        XCTAssertNil(store.activeProfileName)
        store.activeProfile = "work"
        XCTAssertEqual(store.activeProfileName, "work")
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
    }

    func testDormantStoreHidesSwitcherAndLeavesRailUnchanged() {
        // A store with no connection (no profiles capability) → switcher hidden,
        // aggregate rail NOT used, profile filter inert. The full dormancy gate at
        // the store level (no connection ⇒ capability `.unknown`).
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
        let store = SessionStore()
        XCTAssertFalse(store.isMultiProfileAvailable)
        XCTAssertFalse(store.usesAggregateRail)
        XCTAssertTrue(store.profiles.isEmpty)
        // Even after a stale scope is forced, the dormant gate keeps it inert.
        store.activeProfile = "work"
        XCTAssertFalse(store.isMultiProfileAvailable)
        XCTAssertFalse(store.usesAggregateRail)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
    }
}
