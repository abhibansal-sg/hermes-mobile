import Foundation

// MARK: - Control-surface domain types (E5 panels)
//
// Decoded shapes for the gateway's control/admin REST endpoints used by the
// `Views/Panels/` screens: model picker, gateway status, usage analytics,
// cron jobs, and the skills browser. These mirror the live server responses
// (hermes_cli/web_server.py) and are intentionally lenient — every field the
// server can omit or null is optional, so a partial/legacy payload renders
// rather than throwing.
//
// IMPORTANT decoding note: several of these endpoints return *dynamic* keys
// (provider slugs, model ids, personality names, per-model capability maps).
// `JSONDecoder.convertFromSnakeCase` rewrites dictionary keys, which would
// corrupt those. So the dynamic-key endpoints (`/api/model/options`,
// `/api/config`, `/api/skills`, `/api/cron/jobs`) are parsed from a raw
// `JSONValue` with explicit field reads, NOT through the snake-case strategy.
// The fixed-shape endpoints (`/api/model/info`, `/api/analytics/usage`) decode
// via the snake-case strategy.

// MARK: Model options

/// One provider row from `GET /api/model/options` → `providers[]`.
/// Mirrors `hermes_cli.inventory.build_models_payload` rows.
struct ModelProvider: Identifiable, Sendable, Equatable {
    let slug: String
    let name: String
    let isCurrent: Bool
    let isUserDefined: Bool
    let models: [String]
    let totalModels: Int?
    let source: String?
    /// `{model: {fast, reasoning}}` capability map (the REST endpoint requests
    /// capabilities, so this is populated for authenticated providers).
    let capabilities: [String: ModelCapability]

    var id: String { slug }

    init(json: JSONValue) {
        self.slug = json["slug"]?.stringValue ?? ""
        self.name = json["name"]?.stringValue ?? json["slug"]?.stringValue ?? ""
        self.isCurrent = json["is_current"]?.boolValue ?? false
        self.isUserDefined = json["is_user_defined"]?.boolValue ?? false
        self.models = json["models"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.totalModels = json["total_models"]?.intValue
        self.source = json["source"]?.stringValue
        var caps: [String: ModelCapability] = [:]
        if let object = json["capabilities"]?.objectValue {
            for (model, value) in object {
                caps[model] = ModelCapability(json: value)
            }
        }
        self.capabilities = caps
    }
}

/// Per-model capability flags from the `capabilities` map.
struct ModelCapability: Sendable, Equatable {
    let fast: Bool
    let reasoning: Bool

    init(json: JSONValue) {
        self.fast = json["fast"]?.boolValue ?? false
        self.reasoning = json["reasoning"]?.boolValue ?? true
    }
}

/// Decoded `GET /api/model/options` response.
struct ModelOptions: Sendable, Equatable {
    let providers: [ModelProvider]
    /// The currently configured main model id (may be empty).
    let currentModel: String
    /// The currently configured main provider slug (may be empty).
    let currentProvider: String

    init(json: JSONValue) {
        self.providers = json["providers"]?.arrayValue?.map(ModelProvider.init(json:)) ?? []
        self.currentModel = json["model"]?.stringValue ?? ""
        self.currentProvider = json["provider"]?.stringValue ?? ""
    }
}

/// `GET /api/model/info` — resolved metadata for the configured main model.
struct ModelInfo: Decodable, Sendable, Equatable {
    let model: String?
    let provider: String?
    let autoContextLength: Int?
    let configContextLength: Int?
    let effectiveContextLength: Int?
}

/// `POST /api/model/set` result.
struct ModelSetResult: Decodable, Sendable, Equatable {
    let ok: Bool?
    let scope: String?
    let provider: String?
    let model: String?
}

// MARK: Personalities

/// One entry in `agent.personalities` from `GET /api/config`.
///
/// The wire value is either a bare prompt string or an object
/// `{system_prompt, tone?, style?}`. `preview` flattens both into displayable
/// text matching the server's `_render_personality_prompt`.
struct PersonalityOption: Identifiable, Sendable, Equatable {
    /// The personality name (the map key) — this is what `config.set` expects
    /// as `value` (the server lower-cases and validates it).
    let name: String
    let preview: String

    var id: String { name }

    init(name: String, value: JSONValue) {
        self.name = name
        if let prompt = value.stringValue {
            self.preview = prompt
        } else if let object = value.objectValue {
            var parts: [String] = []
            if let sp = object["system_prompt"]?.stringValue, !sp.isEmpty { parts.append(sp) }
            if let tone = object["tone"]?.stringValue, !tone.isEmpty { parts.append("Tone: \(tone)") }
            if let style = object["style"]?.stringValue, !style.isEmpty { parts.append("Style: \(style)") }
            self.preview = parts.joined(separator: "\n")
        } else {
            self.preview = ""
        }
    }
}

// MARK: Gateway status

/// Rich `GET /api/status` snapshot for the gateway panel (superset of the
/// minimal `ServerStatus` the connection layer decodes).
struct GatewayStatus: Sendable, Equatable {
    let version: String?
    let releaseDate: String?
    let hermesHome: String?
    let gatewayRunning: Bool?
    let gatewayPid: Int?
    let gatewayState: String?
    let gatewayExitReason: String?
    let gatewayUpdatedAt: String?
    let activeSessions: Int?
    let authRequired: Bool?
    let authProviders: [String]
    let platforms: [PlatformStatus]
    /// Current config schema version the gateway is running.
    let configVersion: Int?
    /// Latest config schema version supported by this server build. When
    /// `configVersion < latestConfigVersion` a schema upgrade is available.
    let latestConfigVersion: Int?

    /// True when an upgrade to `latestConfigVersion` is available.
    var needsConfigUpgrade: Bool {
        guard let current = configVersion, let latest = latestConfigVersion else { return false }
        return current < latest
    }

    init(json: JSONValue) {
        self.version = json["version"]?.stringValue
        self.releaseDate = json["release_date"]?.stringValue
        self.hermesHome = json["hermes_home"]?.stringValue
        self.gatewayRunning = json["gateway_running"]?.boolValue
        self.gatewayPid = json["gateway_pid"]?.intValue
        self.gatewayState = json["gateway_state"]?.stringValue
        self.gatewayExitReason = json["gateway_exit_reason"]?.stringValue
        self.gatewayUpdatedAt = json["gateway_updated_at"]?.stringValue
        self.activeSessions = json["active_sessions"]?.intValue
        self.authRequired = json["auth_required"]?.boolValue
        self.authProviders = json["auth_providers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.configVersion = json["config_version"]?.intValue
        self.latestConfigVersion = json["latest_config_version"]?.intValue
        if let object = json["gateway_platforms"]?.objectValue {
            self.platforms = object
                .map { PlatformStatus(name: $0.key, json: $0.value) }
                .sorted { $0.name < $1.name }
        } else {
            self.platforms = []
        }
    }
}

/// One platform entry from `gateway_platforms` (telegram, etc.).
struct PlatformStatus: Identifiable, Sendable, Equatable {
    let name: String
    let state: String?
    let errorCode: String?
    let errorMessage: String?
    let updatedAt: String?

    var id: String { name }

    init(name: String, json: JSONValue) {
        self.name = name
        // A platform value is normally `{state, error_code?, …}` but tolerate a
        // bare string state for forward-compatibility.
        if let bare = json.stringValue {
            self.state = bare
            self.errorCode = nil
            self.errorMessage = nil
            self.updatedAt = nil
        } else {
            self.state = json["state"]?.stringValue
            self.errorCode = json["error_code"]?.stringValue
            self.errorMessage = json["error_message"]?.stringValue
            self.updatedAt = json["updated_at"]?.stringValue
        }
    }
}

// MARK: Usage analytics

/// `GET /api/analytics/usage` response.
struct UsageAnalytics: Decodable, Sendable, Equatable {
    let daily: [UsageDay]
    let byModel: [UsageModel]
    let totals: UsageTotals
    let periodDays: Int?
    let skills: UsageSkills?

    enum CodingKeys: String, CodingKey {
        // Decoded with `.convertFromSnakeCase`, so wire keys arrive camelCased.
        case daily, totals, skills, byModel, periodDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.daily = (try? c.decode([UsageDay].self, forKey: .daily)) ?? []
        self.byModel = (try? c.decode([UsageModel].self, forKey: .byModel)) ?? []
        self.totals = (try? c.decode(UsageTotals.self, forKey: .totals)) ?? UsageTotals()
        self.periodDays = try? c.decodeIfPresent(Int.self, forKey: .periodDays)
        self.skills = try? c.decodeIfPresent(UsageSkills.self, forKey: .skills)
    }
}

/// One row of `daily[]` (a calendar day's aggregated usage).
struct UsageDay: Decodable, Sendable, Equatable, Identifiable {
    let day: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let reasoningTokens: Int?
    let estimatedCost: Double?
    let actualCost: Double?
    let sessions: Int?
    let apiCalls: Int?

    var id: String { day }

    /// Total effective tokens for the day (input + output + cache-read), for
    /// chart heights. Desktop counts all three buckets; omitting cache-read
    /// undercounts by ~10x on cache-heavy workloads.
    var totalTokens: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadTokens ?? 0)
    }
}

/// One row of `by_model[]`.
struct UsageModel: Decodable, Sendable, Equatable, Identifiable {
    let model: String
    let inputTokens: Int?
    let outputTokens: Int?
    let estimatedCost: Double?
    let sessions: Int?
    let apiCalls: Int?

    var id: String { model }
    var totalTokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }
}

/// The `totals` block of the usage response.
struct UsageTotals: Decodable, Sendable, Equatable {
    let totalInput: Int?
    let totalOutput: Int?
    let totalCacheRead: Int?
    let totalReasoning: Int?
    let totalEstimatedCost: Double?
    let totalActualCost: Double?
    let totalSessions: Int?
    let totalApiCalls: Int?

    init(totalInput: Int? = nil, totalOutput: Int? = nil, totalCacheRead: Int? = nil,
         totalReasoning: Int? = nil, totalEstimatedCost: Double? = nil,
         totalActualCost: Double? = nil, totalSessions: Int? = nil, totalApiCalls: Int? = nil) {
        self.totalInput = totalInput
        self.totalOutput = totalOutput
        self.totalCacheRead = totalCacheRead
        self.totalReasoning = totalReasoning
        self.totalEstimatedCost = totalEstimatedCost
        self.totalActualCost = totalActualCost
        self.totalSessions = totalSessions
        self.totalApiCalls = totalApiCalls
    }
}

/// The `skills` block of the usage response.
struct UsageSkills: Decodable, Sendable, Equatable {
    let summary: UsageSkillsSummary?
    let topSkills: [UsageSkillRow]?
}

struct UsageSkillsSummary: Decodable, Sendable, Equatable {
    let totalSkillLoads: Int?
    let totalSkillEdits: Int?
    let totalSkillActions: Int?
    let distinctSkillsUsed: Int?
}

struct UsageSkillRow: Decodable, Sendable, Equatable, Identifiable {
    let name: String?
    let count: Int?
    /// Stable identity: the old computed `name ?? UUID().uuidString` minted a
    /// NEW UUID on every access, so ForEach re-identified nameless rows on
    /// every render (release audit P1). The stored fallback is minted once.
    private let fallbackId = UUID().uuidString
    var id: String { name ?? fallbackId }

    private enum CodingKeys: String, CodingKey { case name, count }
}

// MARK: Cron jobs

/// One job from `GET /api/cron/jobs` (and the mutation endpoints, which return
/// the updated job). Timestamps are ISO-8601 strings on the wire.
struct CronJob: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let prompt: String?
    let scheduleDisplay: String?
    /// "scheduled" or "paused".
    let state: String?
    let enabled: Bool
    let nextRunAt: String?
    let lastRunAt: String?
    /// "ok" / "error" / nil (never run).
    let lastStatus: String?
    let lastError: String?
    let source: String?
    let profile: String?

    init(json: JSONValue) {
        self.id = json["id"]?.stringValue ?? UUID().uuidString
        self.name = json["name"]?.stringValue ?? "Untitled job"
        self.prompt = json["prompt"]?.stringValue
        self.scheduleDisplay = json["schedule_display"]?.stringValue
            ?? json["schedule"]?["display"]?.stringValue
        self.state = json["state"]?.stringValue
        self.enabled = json["enabled"]?.boolValue ?? true
        self.nextRunAt = json["next_run_at"]?.stringValue
        self.lastRunAt = json["last_run_at"]?.stringValue
        self.lastStatus = json["last_status"]?.stringValue
        self.lastError = json["last_error"]?.stringValue
        self.source = json["source"]?.stringValue
        self.profile = json["profile"]?.stringValue ?? json["profile_name"]?.stringValue
    }

    /// True when the job is paused or disabled (vs. actively scheduled).
    var isPaused: Bool { state == "paused" || !enabled }
}

// MARK: Skills

/// One skill from `GET /api/skills`.
struct SkillEntry: Identifiable, Sendable, Equatable {
    let name: String
    let description: String?
    let category: String?
    let enabled: Bool

    var id: String { name }

    init(json: JSONValue) {
        self.name = json["name"]?.stringValue ?? ""
        self.description = json["description"]?.stringValue
        self.category = json["category"]?.stringValue
        self.enabled = json["enabled"]?.boolValue ?? true
    }
}

// MARK: - Control-surface endpoints
//
// The control/admin endpoints (model picker, gateway status, usage, cron, skills)
// are true ``RestClient`` extension members, reusing the shared
// `makeRequest`/`perform`/`decode`/`decodeJSONValue` plumbing from
// `RestClient.swift` (loopback `Host` override, `X-Hermes-Session-Token` auth, 15s
// timeout, ``RestError`` mapping) rather than cloning it. The panel views take a
// ``RestClient`` via init (``ConnectionStore.control``).
//
// Fixed-shape responses (`/api/model/info`, `/api/analytics/usage`, `/api/model/set`)
// decode through `.convertFromSnakeCase`. Dynamic-key responses
// (`/api/model/options`, `/api/config`, `/api/cron/jobs`, `/api/skills`) parse from
// a raw ``JSONValue`` so provider/model/personality keys survive verbatim.
extension RestClient {

    // MARK: Model

    /// `GET /api/model/options` — providers + curated models + capabilities.
    func modelOptions() async throws -> ModelOptions {
        ModelOptions(json: try await getJSON(path: "/api/model/options"))
    }

    /// `GET /api/model/info` — resolved metadata for the configured main model.
    func modelInfo() async throws -> ModelInfo {
        try await getDecoded(ModelInfo.self, path: "/api/model/info", context: "model.info")
    }

    /// `POST /api/model/set` — assign provider/model to the main slot. Applies
    /// to *new* sessions; the running chat is unaffected (server semantics).
    @discardableResult
    func setMainModel(provider: String, model: String) async throws -> ModelSetResult {
        let body: JSONValue = .object([
            "scope": .string("main"),
            "provider": .string(provider),
            "model": .string(model),
        ])
        return try await postDecoded(
            ModelSetResult.self, path: "/api/model/set", body: body, context: "model.set"
        )
    }

    // MARK: Config / personalities

    /// `GET /api/config` → the `agent.personalities` map, flattened into a
    /// sorted list of selectable options (empty when none configured).
    func personalities() async throws -> [PersonalityOption] {
        let json = try await getJSON(path: "/api/config")
        guard let map = json["agent"]?["personalities"]?.objectValue else { return [] }
        return map
            .map { PersonalityOption(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// The currently configured personality name (`display.personality`), or
    /// nil when none/empty.
    func currentPersonality() async throws -> String? {
        let json = try await getJSON(path: "/api/config")
        let value = json["display"]?["personality"]?.stringValue
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// `GET /api/config` → the `agent` section as a raw JSONValue.
    /// Used by ModelPickerView to read the global default `reasoning_effort`
    /// and `service_tier` without exposing the full config to callers.
    func agentConfig() async throws -> JSONValue {
        let json = try await getJSON(path: "/api/config")
        return json["agent"] ?? .null
    }

    // MARK: Status

    /// `GET /api/status` — rich gateway snapshot for the status panel.
    func gatewayStatus() async throws -> GatewayStatus {
        GatewayStatus(json: try await getJSON(path: "/api/status"))
    }

    // MARK: Usage

    /// `GET /api/analytics/usage?days=` — totals, per-day, per-model, skills.
    func usageAnalytics(days: Int = 30) async throws -> UsageAnalytics {
        try await getDecoded(
            UsageAnalytics.self, path: "/api/analytics/usage?days=\(days)", context: "usage"
        )
    }

    // MARK: Cron

    /// `GET /api/cron/jobs` — every scheduled job across profiles.
    func cronJobs() async throws -> [CronJob] {
        let json = try await getJSON(path: "/api/cron/jobs")
        return (json.arrayValue ?? []).map(CronJob.init(json:))
    }

    /// `POST /api/cron/jobs/{id}/trigger` — run now; returns the updated job.
    @discardableResult
    func triggerCronJob(id: String) async throws -> CronJob {
        try await cronAction(id: id, action: "trigger")
    }

    /// `POST /api/cron/jobs/{id}/pause`.
    @discardableResult
    func pauseCronJob(id: String) async throws -> CronJob {
        try await cronAction(id: id, action: "pause")
    }

    /// `POST /api/cron/jobs/{id}/resume`.
    @discardableResult
    func resumeCronJob(id: String) async throws -> CronJob {
        try await cronAction(id: id, action: "resume")
    }

    private func cronAction(id: String, action: String) async throws -> CronJob {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return CronJob(json: try await postJSON(path: "/api/cron/jobs/\(encoded)/\(action)"))
    }

    /// `POST /api/cron/jobs` — create a new scheduled job.
    /// Required fields: `prompt`, `schedule`. Optional: `name`, `deliver`.
    @discardableResult
    func createCronJob(name: String?, prompt: String, schedule: String, deliver: String?) async throws -> CronJob {
        var object: [String: JSONValue] = [
            "prompt": .string(prompt),
            "schedule": .string(schedule),
        ]
        if let name, !name.isEmpty { object["name"] = .string(name) }
        if let deliver, !deliver.isEmpty { object["deliver"] = .string(deliver) }
        return CronJob(json: try await postJSON(path: "/api/cron/jobs", body: .object(object)))
    }

    /// `PUT /api/cron/jobs/{id}` — update a job's mutable fields.
    @discardableResult
    func updateCronJob(id: String, name: String?, prompt: String, schedule: String, deliver: String?) async throws -> CronJob {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var updates: [String: JSONValue] = [
            "prompt": .string(prompt),
            "schedule": .string(schedule),
        ]
        if let name { updates["name"] = .string(name) }
        if let deliver { updates["deliver"] = .string(deliver) }
        let body: JSONValue = .object(["updates": .object(updates)])
        return CronJob(json: try await putJSON(path: "/api/cron/jobs/\(encoded)", body: body))
    }

    /// `DELETE /api/cron/jobs/{id}` — permanently delete a job.
    func deleteCronJob(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await perform(makeRequest(path: "/api/cron/jobs/\(encoded)", method: "DELETE"))
    }

    // MARK: Skills

    /// `GET /api/skills` — every discovered skill.
    func skills() async throws -> [SkillEntry] {
        let json = try await getJSON(path: "/api/skills")
        return (json.arrayValue ?? []).map(SkillEntry.init(json:))
    }

    /// `PUT /api/skills/toggle` — enable or disable a skill by name.
    /// Returns the updated enabled state.
    @discardableResult
    func toggleSkill(name: String, enabled: Bool) async throws -> Bool {
        let body: JSONValue = .object(["name": .string(name), "enabled": .bool(enabled)])
        let result = try await putJSON(path: "/api/skills/toggle", body: body)
        return result["enabled"]?.boolValue ?? enabled
    }

    // MARK: - Request helpers (thin wrappers over RestClient's shared plumbing)

    /// `GET` a dynamic-key endpoint as a raw ``JSONValue``.
    private func getJSON(path: String) async throws -> JSONValue {
        try decodeJSONValue(from: try await get(path: path), context: path)
    }

    /// `POST` (optionally with a JSON body) and decode the reply as a raw
    /// ``JSONValue`` (dynamic keys preserved).
    private func postJSON(path: String, body: JSONValue? = nil) async throws -> JSONValue {
        var request = makeRequest(path: path, method: "POST")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encodeBody(body, context: path)
        }
        return try decodeJSONValue(from: try await perform(request), context: path)
    }

    /// `PUT` with a JSON body; decode the reply as a raw ``JSONValue``.
    private func putJSON(path: String, body: JSONValue) async throws -> JSONValue {
        var request = makeRequest(path: path, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeBody(body, context: path)
        return try decodeJSONValue(from: try await perform(request), context: path)
    }

    /// `GET` a fixed-shape endpoint and decode via `.convertFromSnakeCase`.
    private func getDecoded<T: Decodable>(_ type: T.Type, path: String, context: String) async throws -> T {
        try decode(type, from: try await get(path: path), context: context)
    }

    /// `POST` a JSON body to a fixed-shape endpoint and decode the reply via
    /// `.convertFromSnakeCase`.
    private func postDecoded<T: Decodable>(
        _ type: T.Type, path: String, body: JSONValue, context: String
    ) async throws -> T {
        var request = makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeBody(body, context: context)
        return try decode(type, from: try await perform(request), context: context)
    }
}
