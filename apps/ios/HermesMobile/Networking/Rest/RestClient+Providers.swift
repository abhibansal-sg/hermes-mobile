import Foundation

// MARK: - ABH-183 provider / API-key-entry REST surface (feature-detected, plugin-mount)
//
// The four provider/key-entry routes live on the hermes-mobile PLUGIN mount:
//
//   GET    <prefix>/providers               → the provider universe + authenticated?
//   POST   <prefix>/providers/{slug}/key    → Tier A: registered api_key provider
//   POST   <prefix>/providers/custom        → Tier B: custom OpenAI/Anthropic-compatible
//   DELETE <prefix>/providers/{slug}/key    → remove credentials (parity model.disconnect)
//
// They import ONLY stock hermes-agent functions (save_env_value /
// remove_env_value / set_config_value / is_managed, PROVIDER_REGISTRY /
// clear_provider_auth, build_models_payload) — the plugin routes already exist
// from the prior phase; this client speaks to them. Kept on `RestClient`
// (mirroring `RestClient+Devices.swift` / `RestClient+Profiles.swift`) so these
// inherit the loopback `Host` override, the `X-Hermes-Session-Token` auth header,
// the ephemeral session, and the 15s timeout via the shared `makeRequest`/`get`/
// `perform`/`decode`/`decodeJSONValue` plumbing — no cloned HTTP code.
//
// MIGRATION SAFETY: every caller (the Settings "Model Provider" section) gates on
// `capabilities.pluginMount == .available`, so on a stock hermes-agent (no plugin
// mount) the section is hidden and none of this is reached — the app is
// byte-for-byte its pre-ABH-183 self. On a plugin-mount gateway that PREDATES the
// provider routes, the list load surfaces the 404 as an inline error (graceful),
// never a crash.
//
// SECRETS HYGINE (binding): the api_key is held transiently in the Keychain
// (``KeychainService/saveProviderKey(_:slug:)``), POSTed once over the existing
// TLS connection, then the client copy is cleared (``deleteProviderKey``) — the
// gateway is the source of truth. The api_key is NEVER logged: it rides only in
// the POST body (a typed encode into the request, never error-logged on the happy
// path), and the route's response bodies never echo it (the plugin contract).
// `RestError` already truncates bodies to 512 chars in `perform`.

// MARK: Provider domain types

/// The `auth_type` of a provider, as reported by the plugin's `/providers` list.
///
/// Only `api_key` providers can be provisioned from a raw key on mobile
/// (Tier A). The OAuth/external auth types (`oauth_device_code`,
/// `oauth_external`, `oauth_minimax`, `external_process`) CANNOT — the plugin
/// rejects them with a 4003-class "set up on desktop" error (parity with stock
/// `model.save_key`). `custom` marks a provider registered via the Tier B
/// custom-provider route (an OpenAI/Anthropic-compatible endpoint).
enum ProviderAuthType: String, Sendable, Equatable {
    case apiKey = "api_key"
    case oauthDeviceCode = "oauth_device_code"
    case oauthExternal = "oauth_external"
    case oauthMinimax = "oauth_minimax"
    case externalProcess = "external_process"
    /// A custom OpenAI/Anthropic-compatible provider (Tier B).
    case custom = "custom"

    /// Whether this auth type can be provisioned from a raw key on mobile
    /// (Tier A / Tier B). OAuth/external types must be set up on the desktop.
    /// ABH-257: `.custom` is provisionable — tapping an authenticated custom
    /// provider row opens a pre-filled edit/rotate form (same upsert endpoint).
    var provisionableFromKey: Bool { self == .apiKey || self == .custom }
}

/// One provider row from `GET <prefix>/providers`. The plugin's list projects
/// to a mobile-safe shape — it carries the slug, name, auth type, whether it is
/// the current main provider, the per-provider `authenticated` boolean, and the
/// curated model count, but NEVER a key value, env-var contents, or a secret.
///
/// Decoded leniently via a raw ``JSONValue`` read (the same lenient strategy the
/// other dynamic-key endpoints use) so a partial/legacy payload renders rather
/// than throwing. Mirrors the ``ModelProvider`` field set the model picker keys
/// off, minus the per-model list (the list endpoint omits `models`; the
/// key/custom responses include them).
struct ProviderRow: Identifiable, Sendable, Equatable, Hashable {
    let slug: String
    let name: String
    let authType: ProviderAuthType?
    let isCurrent: Bool
    let authenticated: Bool
    let totalModels: Int
    /// The curated model ids (present on the POST key/custom responses; the GET
    /// list omits this). `nil` = unknown / not provided by this response.
    let models: [String]?
    /// ABH-257: base_url for a custom provider (present only on custom rows).
    /// Used to pre-fill the edit/rotate form. `nil` for registered providers.
    let baseURL: String?
    /// ABH-257: api_mode for a custom provider (present only on custom rows).
    /// Used to pre-fill the edit/rotate form. `nil` for registered providers.
    let apiMode: ProviderAPIMode?

    var id: String { slug }

    /// Whether this provider can be provisioned from a raw API key on mobile
    /// (Tier A / Tier B). Delegates to the auth type: `api_key` and `custom`
    /// providers qualify; OAuth/external types must be set up on the desktop
    /// (the plugin rejects them with a 4003-class error), and a row whose
    /// `auth_type` we could not classify is conservatively NOT provisionable
    /// from mobile.
    var provisionableFromKey: Bool { authType?.provisionableFromKey ?? false }

    /// Memberwise init (so the list view can flip a row locally after a
    /// disconnect without re-decoding from JSON).
    init(
        slug: String,
        name: String,
        authType: ProviderAuthType?,
        isCurrent: Bool,
        authenticated: Bool,
        totalModels: Int,
        models: [String]?,
        baseURL: String? = nil,
        apiMode: ProviderAPIMode? = nil
    ) {
        self.slug = slug
        self.name = name
        self.authType = authType
        self.isCurrent = isCurrent
        self.authenticated = authenticated
        self.totalModels = totalModels
        self.models = models
        self.baseURL = baseURL
        self.apiMode = apiMode
    }

    init(json: JSONValue) {
        self.slug = json["slug"]?.stringValue ?? ""
        self.name = json["name"]?.stringValue ?? json["slug"]?.stringValue ?? ""
        let rawAuth = json["auth_type"]?.stringValue ?? ""
        self.authType = ProviderAuthType(rawValue: rawAuth)
        self.isCurrent = json["is_current"]?.boolValue ?? false
        self.authenticated = json["authenticated"]?.boolValue ?? false
        self.totalModels = json["total_models"]?.intValue ?? 0
        if let array = json["models"]?.arrayValue {
            // The custom/key responses carry `models` as a list of `{id}` objects
            // (the inventory builder's row shape); tolerate bare strings too.
            self.models = array.compactMap { $0["id"]?.stringValue ?? $0.stringValue }
        } else {
            self.models = nil
        }
        // ABH-257: custom-provider transport metadata for the edit/rotate form.
        self.baseURL = json["base_url"]?.stringValue
        let rawMode = json["api_mode"]?.stringValue ?? ""
        self.apiMode = rawMode.isEmpty ? nil : ProviderAPIMode(rawValue: rawMode)
    }
}

/// `POST <prefix>/providers/{slug}/key` and `POST <prefix>/providers/custom`
/// response. The refreshed provider row is nested under `provider`; validation
/// result fields are siblings at the response root. A definitive
/// `validated == false` means the key was persisted but rejected by the upstream
/// provider, so callers should keep entry UI open and show `validationDetail`.
struct ProviderKeyResult: Sendable, Equatable {
    let row: ProviderRow
    let validated: Bool?
    let validationDetail: String?
    let persisted: Bool?

    init(root: JSONValue) {
        let providerJSON = root["provider"] ?? root
        self.row = ProviderRow(json: providerJSON)
        self.validated = root["validated"]?.boolValue
        self.validationDetail = root["validation_detail"]?.stringValue
        self.persisted = root["persisted"]?.boolValue
    }
}

/// `DELETE <prefix>/providers/{slug}/key` result — the slug + name + a
/// `disconnected` flag.
struct ProviderDisconnectResult: Sendable, Equatable {
    let slug: String
    let name: String
    let disconnected: Bool

    init(json: JSONValue) {
        self.slug = json["slug"]?.stringValue ?? ""
        self.name = json["name"]?.stringValue ?? json["slug"]?.stringValue ?? ""
        self.disconnected = json["disconnected"]?.boolValue ?? false
    }
}

/// The `api_mode` of a custom (Tier B) provider — OpenAI-compatible chat
/// completions or Anthropic messages. Mirrors the plugin's allowed set.
enum ProviderAPIMode: String, Sendable, CaseIterable, Identifiable {
    case openai
    case anthropicMessages = "anthropic_messages"

    var id: String { rawValue }

    /// The human-readable label for the custom-provider picker.
    var label: String {
        switch self {
        case .openai: return "OpenAI-compatible"
        case .anthropicMessages: return "Anthropic Messages"
        }
    }
}

// MARK: - Provider/key-entry endpoints

extension RestClient {

    // MARK: - Capability probe (eager, side-effect-free)

    /// Side-effect-free probe of `GET <prefix>/providers` — the provider list,
    /// which arrives only on plugin-mount gateways whose plugin build carries the
    /// ABH-183 routes. A supporting server returns `200` with a well-formed
    /// `{"providers":[…]}` body (route exists ⇒ available — even an EMPTY list is
    /// a 200, NOT a 404, so the panel renders with zero rows); a gateway without
    /// the route returns `404`/`405` (unavailable). The probe is a READ — no key
    /// is set, removed, or echoed. Never throws — failures map to `.inconclusive`.
    /// Shapes its result as the SAME ``UploadProbeResult`` the other probes use so
    /// ``ServerCapabilities`` folds it with one switch if a dedicated capability is
    /// added later.
    ///
    /// Refinement (mirroring `probeDevicesEndpoint`): a `200` must ALSO carry a
    /// `providers` array to count as `.available`; a `200` lacking one is
    /// `.inconclusive` (defensive against a same-path collision).
    func probeProvidersEndpoint() async -> UploadProbeResult {
        let request = makeRequest(path: "\(mobileAPIPrefix)/providers", method: "GET")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .inconclusive }
            switch http.statusCode {
            case 200:
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["providers"] is [Any] {
                    return .available
                }
                return .inconclusive
            case 404, 405:
                return .unavailable
            default:
                return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }

    // MARK: - List the provider universe (the picker's data)

    /// `GET <prefix>/providers` → decode `{"providers":[…]}` into the
    /// ``ProviderRow`` rows the Model Provider picker renders. Reveals names +
    /// slugs + auth type + the per-provider `authenticated` boolean ONLY — NEVER
    /// a key value or secret (the plugin contract). Server order is the inventory
    /// order. Throws ``RestError`` (e.g. `badStatus(401, …)` on a bad/absent
    /// credential) for the caller to map to a native inline error.
    func listProviders() async throws -> [ProviderRow] {
        let data = try await get(path: "\(mobileAPIPrefix)/providers")
        let root = try decodeJSONValue(from: data, context: "providers.list")
        let array = root["providers"]?.arrayValue
            ?? (root.arrayValue ?? [])
        return array.map(ProviderRow.init(json:))
    }

    // MARK: - Tier A — save an API key for a registered api_key provider

    /// `POST <prefix>/providers/{slug}/key {"api_key"}` — Tier A: persist an API
    /// key for a REGISTERED `api_key` provider. The plugin validates the slug is
    /// a known PROVIDER_REGISTRY entry with `auth_type == "api_key"` (else a
    /// 4003-class "set up on desktop" reject for OAuth-only providers), honours
    /// `is_managed()` (4006 read-only for managed installs), and persists via the
    /// stock `save_env_value`. Returns the refreshed provider row with models
    /// populated and `authenticated == true`, plus root-level validation status.
    /// NEVER echoes the key.
    ///
    /// `apiKey` is held transiently in the Keychain by the caller
    /// (``KeychainService/saveProviderKey``) for this POST, then deleted — the
    /// gateway is the source of truth. Throws ``RestError`` (`badStatus`) on a
    /// 4003/4006 structural reject; an upstream key reject can arrive as a
    /// successful response with `validated == false` and `validation_detail`.
    @discardableResult
    func setProviderKey(slug: String, apiKey: String) async throws -> ProviderKeyResult {
        let encodedSlug = slug.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? slug
        var request = makeRequest(
            path: "\(mobileAPIPrefix)/providers/\(encodedSlug)/key", method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object(["api_key": .string(apiKey)])
        request.httpBody = try encodeBody(body, context: "providers.setKey")
        let data = try await perform(request)
        let root = try decodeJSONValue(from: data, context: "providers.setKey")
        // The response is `{"provider": {…}, "validated": …}`; tolerate a bare provider object.
        return ProviderKeyResult(root: root)
    }

    // MARK: - Tier B — register a custom OpenAI/Anthropic-compatible provider

    /// `POST <prefix>/providers/custom {"name","base_url","api_mode","api_key"}` —
    /// Tier B: register a custom provider. The plugin writes
    /// `providers.<name>.{name,base_url,api_mode,api_key}` via the stock
    /// `set_config_value` (the same path the desktop `hermes set` uses). Validates
    /// the name is a safe dotted-key segment, the base_url is an http(s) URL, the
    /// api_mode is in the allowed set, and the api_key is non-empty. Honours
    /// `is_managed()` (4006). Returns the refreshed provider row with
    /// `authenticated == true`, plus root-level validation status. NEVER echoes
    /// the key.
    ///
    /// `apiKey` is held transiently in the Keychain by the caller, then deleted.
    /// Throws ``RestError`` (`badStatus`) on a structural validation/managed
    /// reject; an upstream key reject can arrive as a successful response with
    /// `validated == false` and `validation_detail`.
    @discardableResult
    func addCustomProvider(
        name: String,
        baseURL: String,
        apiMode: ProviderAPIMode,
        apiKey: String
    ) async throws -> ProviderKeyResult {
        var request = makeRequest(
            path: "\(mobileAPIPrefix)/providers/custom", method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "name": .string(name),
            "base_url": .string(baseURL),
            "api_mode": .string(apiMode.rawValue),
            "api_key": .string(apiKey),
        ])
        request.httpBody = try encodeBody(body, context: "providers.custom")
        let data = try await perform(request)
        let root = try decodeJSONValue(from: data, context: "providers.custom")
        return ProviderKeyResult(root: root)
    }

    // MARK: - Remove credentials (parity model.disconnect)

    /// `DELETE <prefix>/providers/{slug}/key` — remove credentials for a provider.
    /// For a registered api_key provider: `remove_env_value` on each env var. For
    /// a custom provider: `clear_provider_auth`. Honours `is_managed()` (4006).
    /// Returns the slug + name + a `disconnected` flag. NEVER echoes a key.
    /// Throws ``RestError`` (`badStatus`) on a managed reject or when no
    /// credentials were found (4005).
    @discardableResult
    func removeProviderKey(slug: String) async throws -> ProviderDisconnectResult {
        let encodedSlug = slug.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? slug
        let request = makeRequest(
            path: "\(mobileAPIPrefix)/providers/\(encodedSlug)/key", method: "DELETE"
        )
        let data = try await perform(request)
        let root = try decodeJSONValue(from: data, context: "providers.removeKey")
        return ProviderDisconnectResult(json: root)
    }
}


// MARK: - ABH-262 toolset credential REST surface (plugin-mount)
//
// The mobile plugin exposes desktop-parity toolset credential config at:
//
//   GET <prefix>/toolsets/{name}/config
//   PUT <prefix>/toolsets/{name}/config {"key":"ENV_VAR", "value":"..."}
//
// The GET response is explicitly redacted: env vars carry `is_set` only, never
// the stored value. PUT with an empty value clears the env var. This extension
// keeps the iOS app on the same RestClient plumbing as the provider-key surface
// (Host override, X-Hermes-Session-Token auth header, timeout, JSON helpers).

// MARK: Toolset config domain types

struct ToolsetConfig: Identifiable, Sendable, Equatable {
    let name: String
    let hasCategory: Bool
    let providers: [ToolsetConfigProvider]
    let activeProvider: String?

    var id: String { name }

    var displayName: String { Self.displayName(for: name) }

    var configuredCredentialCount: Int {
        providers.reduce(0) { total, provider in
            total + provider.envVars.filter(\.isSet).count
        }
    }

    var credentialCount: Int {
        providers.reduce(0) { $0 + $1.envVars.count }
    }

    var hasConfiguredCredential: Bool { configuredCredentialCount > 0 }

    init(
        name: String,
        hasCategory: Bool,
        providers: [ToolsetConfigProvider],
        activeProvider: String?
    ) {
        self.name = name
        self.hasCategory = hasCategory
        self.providers = providers
        self.activeProvider = activeProvider
    }

    init(json: JSONValue) {
        let name = json["name"]?.stringValue ?? ""
        self.name = name
        self.hasCategory = json["has_category"]?.boolValue ?? false
        self.activeProvider = json["active_provider"]?.stringValue
        self.providers = (json["providers"]?.arrayValue ?? []).map {
            ToolsetConfigProvider(json: $0, toolsetName: name)
        }
    }

    static func displayName(for name: String) -> String {
        switch name {
        case "web": return "Web Search"
        case "image_gen": return "Image Generation"
        default:
            return name
                .split(separator: "_")
                .map { part in
                    String(part.prefix(1)).uppercased() + String(part.dropFirst())
                }
                .joined(separator: " ")
        }
    }
}

struct ToolsetConfigProvider: Identifiable, Sendable, Equatable {
    let toolsetName: String
    let name: String
    let badge: String
    let tag: String
    let envVars: [ToolsetEnvVar]
    let postSetup: String?
    let requiresNousAuth: Bool
    let isActive: Bool

    var id: String { "\(toolsetName)::\(name)::\(tag)::\(badge)" }

    init(
        toolsetName: String,
        name: String,
        badge: String,
        tag: String,
        envVars: [ToolsetEnvVar],
        postSetup: String?,
        requiresNousAuth: Bool,
        isActive: Bool
    ) {
        self.toolsetName = toolsetName
        self.name = name
        self.badge = badge
        self.tag = tag
        self.envVars = envVars
        self.postSetup = postSetup
        self.requiresNousAuth = requiresNousAuth
        self.isActive = isActive
    }

    init(json: JSONValue, toolsetName: String) {
        self.toolsetName = toolsetName
        self.name = json["name"]?.stringValue ?? ""
        self.badge = json["badge"]?.stringValue ?? ""
        self.tag = json["tag"]?.stringValue ?? ""
        self.envVars = (json["env_vars"]?.arrayValue ?? []).map(ToolsetEnvVar.init(json:))
        self.postSetup = json["post_setup"]?.stringValue
        self.requiresNousAuth = json["requires_nous_auth"]?.boolValue ?? false
        self.isActive = json["is_active"]?.boolValue ?? false
    }
}

struct ToolsetEnvVar: Identifiable, Sendable, Equatable, Hashable {
    let key: String
    let prompt: String
    let url: String?
    let defaultValue: String?
    let isSet: Bool

    var id: String { key }

    init(key: String, prompt: String, url: String?, defaultValue: String?, isSet: Bool) {
        self.key = key
        self.prompt = prompt
        self.url = url
        self.defaultValue = defaultValue
        self.isSet = isSet
    }

    init(json: JSONValue) {
        self.key = json["key"]?.stringValue ?? ""
        self.prompt = json["prompt"]?.stringValue ?? json["key"]?.stringValue ?? ""
        self.url = json["url"]?.stringValue
        self.defaultValue = json["default"]?.stringValue
        self.isSet = json["is_set"]?.boolValue ?? false
    }
}

enum ToolsetConfigCatalog {
    /// The server currently exposes toolset config one toolset at a time rather
    /// than a list endpoint. Keep this starter set aligned with the shipped top
    /// non-model credential panels ABH-262 asked to surface on iOS.
    /// "web" (Web Search) and "image_gen" (Image Generation) are the gateway's
    /// canonical configurable toolset keys (CONFIGURABLE_TOOLSETS in
    /// hermes_cli/tools_config.py). The individual TOOLS web_search / web_extract
    /// live INSIDE the "web" toolset — the config path segment is "web", not
    /// "web_search".
    static let configurableNames = ["web", "image_gen"]
}

// MARK: - Toolset credential endpoints

extension RestClient {

    /// `GET <prefix>/toolsets/{name}/config` — returns provider/env-var status
    /// for one toolset. The response never includes a stored secret value.
    func getToolsetConfig(name: String) async throws -> ToolsetConfig {
        let encodedName = name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? name
        let data = try await get(path: "\(mobileAPIPrefix)/toolsets/\(encodedName)/config")
        let root = try decodeJSONValue(from: data, context: "toolsets.config")
        return ToolsetConfig(json: root)
    }

    /// `PUT <prefix>/toolsets/{name}/config` — set or clear an env-var credential.
    /// Passing `nil` or an empty string clears the key. The refreshed config is
    /// returned and remains redacted (`is_set` booleans only).
    @discardableResult
    func setToolsetCredential(name: String, key: String, value: String?) async throws -> ToolsetConfig {
        let encodedName = name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? name
        var request = makeRequest(
            path: "\(mobileAPIPrefix)/toolsets/\(encodedName)/config", method: "PUT"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "key": .string(key),
            "value": .string(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
        ])
        request.httpBody = try encodeBody(body, context: "toolsets.setConfig")
        let data = try await perform(request)
        let root = try decodeJSONValue(from: data, context: "toolsets.setConfig")
        return ToolsetConfig(json: root)
    }
}
