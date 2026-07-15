import Foundation

// MARK: - STR-338 webhook subscription management REST surface (stock gateway routes)
//
// The dashboard's Webhooks page (`web/src/pages/WebhooksPage.tsx`) manages a
// separate gateway "platform" — an inbound HTTP receiver that fires the agent
// (or delivers a payload directly) on named, HMAC-signed subscriptions. The
// five routes below are STOCK gateway routes (`hermes_cli/web_server.py`,
// same server family as `/api/logs`), NOT the hermes-mobile plugin mount, so
// they hang off `/api/webhooks` directly regardless of this client's
// `pathStyle` — mirrors `RestClient/systemLogs`'s "stock route" posture.
//
//   GET    /api/webhooks                → receiver state + subscription list
//   POST   /api/webhooks/enable         → flip the webhook platform on
//   POST   /api/webhooks                → create a subscription (returns the
//                                          one-time HMAC secret)
//   DELETE /api/webhooks/{name}         → remove a subscription
//   PUT    /api/webhooks/{name}/enabled → toggle a subscription on/off
//
// Kept on `RestClient` (mirroring `RestClient+Providers.swift` /
// `RestClient+FS.swift`) so these inherit the loopback `Host` override, the
// `X-Hermes-Session-Token` auth header, the ephemeral session, and the 15s
// timeout via the shared `makeRequest`/`get`/`perform`/`encodeBody`/
// `decodeJSONValue` plumbing — no cloned HTTP code.
//
// SECRETS HYGIENE (binding): the per-route HMAC secret is returned by the
// gateway EXACTLY ONCE, on `POST /api/webhooks` — every other read (the list,
// the toggle, the delete) is redacted to a `secret_set` boolean. This client
// never re-requests or persists the secret; the caller (``WebhooksPanelView``)
// shows it once in a "copy now" affordance and discards it when the sheet
// closes. `RestError` already truncates bodies to 512 chars in `perform`.

// MARK: - Domain types

/// One webhook subscription row from `GET /api/webhooks`. Decoded leniently
/// via a raw ``JSONValue`` read (the same lenient strategy the provider/
/// toolset endpoints use) so a partial/legacy payload renders rather than
/// throwing, and so an unrecognized/added field degrades gracefully instead
/// of failing the whole list.
struct WebhookRoute: Identifiable, Sendable, Equatable {
    let name: String
    let description: String
    let events: [String]
    let deliver: String
    let deliverOnly: Bool
    let prompt: String
    /// A future/optional server-side script hook. The current gateway
    /// (`_webhook_route_summary` in `hermes_cli/web_server.py`) does not emit
    /// this field — it is decoded defensively (`nil` today) so the client
    /// tolerates a future addition without a wire-format bump.
    let script: String?
    let skills: [String]
    let createdAt: String?
    let url: String
    /// Redacted secret status — the actual secret is NEVER present here (it
    /// rides only in the one-time `POST /api/webhooks` response).
    let secretSet: Bool
    let enabled: Bool

    var id: String { name }

    init(
        name: String,
        description: String,
        events: [String],
        deliver: String,
        deliverOnly: Bool,
        prompt: String,
        script: String? = nil,
        skills: [String],
        createdAt: String?,
        url: String,
        secretSet: Bool,
        enabled: Bool
    ) {
        self.name = name
        self.description = description
        self.events = events
        self.deliver = deliver
        self.deliverOnly = deliverOnly
        self.prompt = prompt
        self.script = script
        self.skills = skills
        self.createdAt = createdAt
        self.url = url
        self.secretSet = secretSet
        self.enabled = enabled
    }

    init(json: JSONValue) {
        self.name = json["name"]?.stringValue ?? ""
        self.description = json["description"]?.stringValue ?? ""
        self.events = (json["events"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.deliver = json["deliver"]?.stringValue ?? "log"
        self.deliverOnly = json["deliver_only"]?.boolValue ?? false
        self.prompt = json["prompt"]?.stringValue ?? ""
        self.script = json["script"]?.stringValue
        self.skills = (json["skills"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.createdAt = json["created_at"]?.stringValue
        self.url = json["url"]?.stringValue ?? ""
        self.secretSet = json["secret_set"]?.boolValue ?? false
        // Server default-enabled: `_webhook_route_summary` treats an absent
        // `enabled` key as `true` (only an explicit `false` turns a route off).
        self.enabled = json["enabled"]?.boolValue ?? true
    }

    /// Local optimistic copy (flip `enabled` without a round-trip re-decode) —
    /// mirrors ``ProviderRow/copy(isCurrent:authenticated:)``.
    func copy(enabled: Bool) -> WebhookRoute {
        WebhookRoute(
            name: name,
            description: description,
            events: events,
            deliver: deliver,
            deliverOnly: deliverOnly,
            prompt: prompt,
            script: script,
            skills: skills,
            createdAt: createdAt,
            url: url,
            secretSet: secretSet,
            enabled: enabled
        )
    }
}

/// `GET /api/webhooks` response: whether the webhook receiver platform is
/// enabled, the base URL subscription URLs are built from, and the current
/// subscription list.
struct WebhooksListResult: Sendable, Equatable {
    let enabled: Bool
    let baseURL: String
    /// `var` so the panel's optimistic toggle/delete can splice a row without
    /// a full re-fetch (mirrors the mutable-local-copy pattern other panels
    /// use, e.g. `CronJobsView.act`).
    var subscriptions: [WebhookRoute]

    init(
        enabled: Bool,
        baseURL: String,
        subscriptions: [WebhookRoute]
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.subscriptions = subscriptions
    }

    init(json: JSONValue) {
        self.enabled = json["enabled"]?.boolValue ?? false
        self.baseURL = json["base_url"]?.stringValue ?? ""
        self.subscriptions = (json["subscriptions"]?.arrayValue ?? []).map(WebhookRoute.init(json:))
    }
}

/// `POST /api/webhooks/enable` response. `needsRestart` is the server's own
/// `not restart_started` computation; `restartStarted == false` means the
/// gateway attempted (and failed) an automatic restart, in which case the
/// caller surfaces `restartError` as an informational "restart manually"
/// message rather than treating the enable call itself as failed (the
/// platform flag WAS persisted).
struct WebhookEnableResult: Sendable, Equatable {
    let ok: Bool
    let enabled: Bool
    let needsRestart: Bool
    let restartStarted: Bool?
    let restartError: String?

    init(json: JSONValue) {
        self.ok = json["ok"]?.boolValue ?? false
        self.enabled = json["enabled"]?.boolValue ?? false
        self.needsRestart = json["needs_restart"]?.boolValue ?? false
        self.restartStarted = json["restart_started"]?.boolValue
        self.restartError = json["restart_error"]?.stringValue
    }
}

// MARK: - Endpoints

extension RestClient {

    /// `GET /api/webhooks` — the receiver's enabled state + subscription list.
    /// A gateway older than STR-338 (no webhook routes at all) 404s; the
    /// caller (``WebhooksPanelView``) surfaces that as an inline error, same
    /// posture as `ProvidersView` on a pre-ABH-183 gateway.
    func listWebhooks() async throws -> WebhooksListResult {
        // /api/webhooks is a STOCK gateway route (not a plugin-mount route),
        // so it hangs off /api directly regardless of pathStyle — mirrors
        // `systemLogs`.
        let data = try await get(path: "/api/webhooks")
        let root = try decodeJSONValue(from: data, context: "webhooks.list")
        return WebhooksListResult(json: root)
    }

    /// `POST /api/webhooks/enable` — flip the webhook receiver platform on.
    /// The gateway attempts a self-restart so the receiver actually starts
    /// listening; `restartStarted == false` on the result means that attempt
    /// failed and the caller should show an informational "gateway needs a
    /// manual restart" message rather than treating the whole call as an
    /// error (the enable flag itself was persisted either way).
    @discardableResult
    func enableWebhooks() async throws -> WebhookEnableResult {
        let request = makeRequest(path: "/api/webhooks/enable", method: "POST")
        let data = try await perform(request)
        let root = try decodeJSONValue(from: data, context: "webhooks.enable")
        return WebhookEnableResult(json: root)
    }

    /// `POST /api/webhooks {"name","description","events","prompt","skills",
    /// "deliver","deliver_only","deliver_chat_id"}` — create a subscription.
    /// The server lowercases + hyphenates the name, rejects a name that still
    /// doesn't match `^[a-z0-9][a-z0-9_-]*$`, and rejects `deliver_only` when
    /// `deliver == "log"` (needs a real target) — both surface as
    /// ``RestError/badStatus(400, …)`` with a FastAPI `{"detail": …}` body the
    /// caller renders inline. Also 400s with a `detail` message when the
    /// webhook platform isn't enabled yet.
    ///
    /// Returns the refreshed ``WebhookRoute`` plus the one-time HMAC `secret`
    /// — the ONLY response that ever carries the real secret value. The
    /// caller must show it once (copy affordance) and never re-request it.
    @discardableResult
    func createWebhook(
        name: String,
        description: String? = nil,
        events: [String] = [],
        prompt: String? = nil,
        skills: [String] = [],
        deliver: String = "log",
        deliverOnly: Bool = false,
        deliverChatId: String? = nil
    ) async throws -> (route: WebhookRoute, secret: String) {
        var request = makeRequest(path: "/api/webhooks", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var fields: [String: JSONValue] = [
            "name": .string(name),
            "deliver": .string(deliver),
            "deliver_only": .bool(deliverOnly),
        ]
        if let description, !description.isEmpty {
            fields["description"] = .string(description)
        }
        if !events.isEmpty {
            fields["events"] = .array(events.map(JSONValue.string))
        }
        if let prompt, !prompt.isEmpty {
            fields["prompt"] = .string(prompt)
        }
        if !skills.isEmpty {
            fields["skills"] = .array(skills.map(JSONValue.string))
        }
        if let deliverChatId, !deliverChatId.isEmpty {
            fields["deliver_chat_id"] = .string(deliverChatId)
        }
        request.httpBody = try encodeBody(.object(fields), context: "webhooks.create")
        let data = try await perform(request)
        let root = try decodeJSONValue(from: data, context: "webhooks.create")
        let route = WebhookRoute(json: root)
        // The secret rides ONLY this response, as a root-level sibling field
        // (`_webhook_route_summary`'s dict plus `summary["secret"] = secret`).
        let secret = root["secret"]?.stringValue ?? ""
        return (route, secret)
    }

    /// `DELETE /api/webhooks/{name}` — remove a subscription. 404s (mapped to
    /// ``RestError/badStatus(404, …)``) when the name is unknown.
    @discardableResult
    func deleteWebhook(name: String) async throws -> Bool {
        let encodedName = name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? name
        let request = makeRequest(path: "/api/webhooks/\(encodedName)", method: "DELETE")
        let data = try await perform(request)
        let root = try decodeJSONValue(from: data, context: "webhooks.delete")
        return root["ok"]?.boolValue ?? true
    }

    /// `PUT /api/webhooks/{name}/enabled {"enabled"}` — toggle a subscription
    /// on/off. Disabled subscriptions stay configured (re-enable-able) but the
    /// receiver rejects their incoming events with 403; this hot-reloads
    /// without a gateway restart. Returns the confirmed `enabled` value from
    /// the response (mirrors the request on success).
    @discardableResult
    func setWebhookEnabled(name: String, enabled: Bool) async throws -> Bool {
        let encodedName = name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? name
        var request = makeRequest(
            path: "/api/webhooks/\(encodedName)/enabled", method: "PUT"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeBody(
            .object(["enabled": .bool(enabled)]), context: "webhooks.setEnabled"
        )
        let data = try await perform(request)
        let root = try decodeJSONValue(from: data, context: "webhooks.setEnabled")
        return root["enabled"]?.boolValue ?? enabled
    }
}
