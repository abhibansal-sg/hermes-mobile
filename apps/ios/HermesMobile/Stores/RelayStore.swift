import SwiftUI

/// Observable owner for the Settings → Relay Push panel.
///
/// Relay mode is configured by the gateway's env-backed relay_client storage:
/// a non-empty relay URL enables relay push, and the registration token is a
/// write-only secret. The store mirrors that contract: it can show whether a
/// token exists and its short prefix, but it never reads or renders the raw
/// token value returned from the server (the route never sends one).
@MainActor
@Observable
final class RelayStore {
    private let rest: RestClient

    var enabled = false
    var relayURLDraft = ""
    var tokenDraft = ""
    var clearTokenOnSave = false

    var registrationTokenSet = false
    var registrationTokenPrefix: String?
    var pushKinds: [String] = []

    var isLoading = false
    var isSaving = false
    var isPairing = false
    var errorMessage: String?
    var savedMessage: String?
    var pairingMessage: String?
    var relayPairing: RelayPairingPayload?

    init(rest: RestClient) {
        self.rest = rest
    }

    var configuredSummary: String {
        if enabled, !relayURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Relay push is configured."
        }
        return "Relay push is off; direct APNs remains unchanged."
    }

    var tokenSummary: String {
        if clearTokenOnSave { return "Token will be cleared on save." }
        guard registrationTokenSet else { return "No registration token saved." }
        if let prefix = registrationTokenPrefix, !prefix.isEmpty {
            return "Registration token saved (prefix \(prefix)…). Leave blank to keep it."
        }
        return "Registration token saved. Leave blank to keep it."
    }

    var pushKindsSummary: String {
        pushKinds.isEmpty ? "—" : pushKinds.joined(separator: ", ")
    }

    var pairingSummary: String? {
        guard let relayPairing else { return nil }
        return "Relay \(relayPairing.relayURL), agent \(relayPairing.agentID), pairing prefix \(relayPairing.pairingPrefix)…"
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        savedMessage = nil
        pairingMessage = nil
        defer { isLoading = false }
        do {
            apply(try await fetchConfig())
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func save() async {
        guard !isSaving else { return }
        errorMessage = nil
        savedMessage = nil
        pairingMessage = nil

        let trimmedURL = relayURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled && trimmedURL.isEmpty {
            errorMessage = "Enter an HTTPS relay URL, or turn Relay Push off."
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            let tokenToWrite: String?
            let trimmedToken = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if clearTokenOnSave {
                tokenToWrite = ""
            } else if trimmedToken.isEmpty {
                tokenToWrite = nil
            } else {
                tokenToWrite = trimmedToken
            }
            let config = try await writeConfig(
                relayURL: enabled ? trimmedURL : "",
                registrationToken: tokenToWrite
            )
            apply(config)
            savedMessage = "Relay settings saved."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func pair() async {
        guard !isPairing else { return }
        errorMessage = nil
        savedMessage = nil
        pairingMessage = nil
        isPairing = true
        defer { isPairing = false }
        do {
            let payload = try await fetchPairing()
            relayPairing = payload
            pairingMessage = "Relay pairing ready for this device."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func apply(_ config: RelayConfig) {
        enabled = !(config.relayURL ?? "").isEmpty
        relayURLDraft = config.relayURL ?? ""
        tokenDraft = ""
        clearTokenOnSave = false
        registrationTokenSet = config.registrationTokenSet
        registrationTokenPrefix = config.registrationTokenPrefix
        pushKinds = config.pushKinds
        relayPairing = nil
    }

    private func fetchConfig() async throws -> RelayConfig {
        let data = try await rest.get(path: "\(rest.mobileAPIPrefix)/relay/config")
        let root = try rest.decodeJSONValue(from: data, context: "relay.config")
        return RelayConfig(json: root)
    }

    private func writeConfig(
        relayURL: String,
        registrationToken: String?
    ) async throws -> RelayConfig {
        var request = rest.makeRequest(
            path: "\(rest.mobileAPIPrefix)/relay/config",
            method: "PUT"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: JSONValue] = ["relay_url": .string(relayURL)]
        if let registrationToken {
            body["registration_token"] = .string(registrationToken)
        }
        request.httpBody = try rest.encodeBody(
            .object(body),
            context: "relay.config"
        )
        let data = try await rest.perform(request)
        let root = try rest.decodeJSONValue(from: data, context: "relay.config")
        return RelayConfig(json: root)
    }

    private func fetchPairing() async throws -> RelayPairingPayload {
        let request = rest.makeRequest(
            path: "\(rest.mobileAPIPrefix)/relay/pair",
            method: "POST"
        )
        let data = try await rest.perform(request)
        let root = try rest.decodeJSONValue(from: data, context: "relay.pair")
        return RelayPairingPayload(json: root)
    }
}

struct RelayConfig: Sendable, Equatable {
    let relayURL: String?
    let registrationTokenSet: Bool
    let registrationTokenPrefix: String?
    let pushKinds: [String]

    init(json: JSONValue) {
        let rawURL = json["relay_url"]?.stringValue ?? ""
        self.relayURL = rawURL.isEmpty ? nil : rawURL
        self.registrationTokenSet = json["registration_token_set"]?.boolValue ?? false
        self.registrationTokenPrefix = json["registration_token_prefix"]?.stringValue
        self.pushKinds = json["push_kinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

struct RelayPairingPayload: Sendable, Equatable {
    let relayURL: String
    let agentID: String
    let pairingSecret: String

    var pairingPrefix: String { String(pairingSecret.prefix(8)) }

    init(json: JSONValue) {
        self.relayURL = json["relay"]?.stringValue ?? ""
        self.agentID = json["agent"]?.stringValue ?? ""
        self.pairingSecret = json["pairing"]?.stringValue ?? ""
    }
}
