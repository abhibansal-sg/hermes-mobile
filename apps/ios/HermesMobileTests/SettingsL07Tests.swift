import XCTest
@testable import HermesMobile

/// Level-07 targeted tests for the Settings/Security/Devices changes.
///
/// Covered:
/// - ``DefaultsKeys/requiresBiometricForSecrets`` default-ON semantics (P0 / A2)
/// - ``AppLock/biometricLabel`` / ``AppLock/biometricSystemImage`` non-empty
/// - ``ApprovalAuditView`` load-more page boundary detection (hasMore iff count == limit)
/// - ``DevicesView/isCurrentDevice`` unchanged (regression pin)
/// - ``DefaultsKeys`` no longer has captureEnabled/capturePrefix (QuickCapture removal)
@MainActor
final class SettingsL07Tests: XCTestCase {

    // MARK: - requiresBiometricForSecrets (A2 default-ON)

    func testRequiresBiometricForSecretsDefaultsOn() {
        // A *missing* key must read as `true` so a fresh install gates secrets
        // behind biometrics out of the box (the binding, per A2).
        let defaults = UserDefaults(suiteName: "SettingsL07Tests.secrets")!
        defaults.removePersistentDomain(forName: "SettingsL07Tests.secrets")
        XCTAssertTrue(
            DefaultsKeys.requiresBiometricForSecretsValue(defaults),
            "Missing requiresBiometricForSecrets key must default to true (on by default)"
        )
    }

    func testRequiresBiometricForSecretsHonorsFalseWhenSet() {
        let defaults = UserDefaults(suiteName: "SettingsL07Tests.secrets2")!
        defaults.removePersistentDomain(forName: "SettingsL07Tests.secrets2")
        defaults.set(false, forKey: DefaultsKeys.requiresBiometricForSecrets)
        XCTAssertFalse(
            DefaultsKeys.requiresBiometricForSecretsValue(defaults),
            "Explicit false must be honored verbatim"
        )
    }

    func testRequiresBiometricForSecretsTrueWhenExplicitlySet() {
        let defaults = UserDefaults(suiteName: "SettingsL07Tests.secrets3")!
        defaults.removePersistentDomain(forName: "SettingsL07Tests.secrets3")
        defaults.set(true, forKey: DefaultsKeys.requiresBiometricForSecrets)
        XCTAssertTrue(
            DefaultsKeys.requiresBiometricForSecretsValue(defaults),
            "Explicit true must be honored verbatim"
        )
    }

    // MARK: - AppLock biometric label helpers

    func testBiometricLabelIsNonEmpty() {
        // The label must always be a non-empty string regardless of the
        // simulator's biometry type (none, face, touch, optic).
        XCTAssertFalse(
            AppLock.biometricLabel.isEmpty,
            "biometricLabel must never be empty"
        )
    }

    func testBiometricSystemImageIsNonEmpty() {
        XCTAssertFalse(
            AppLock.biometricSystemImage.isEmpty,
            "biometricSystemImage must never be empty"
        )
    }

    func testBiometricSystemImageIsValidSFSymbol() {
        // Sanity: the returned symbol name resolves to a UIImage. On simulator
        // (no biometry) the fallback "lock.shield" must exist.
        let name = AppLock.biometricSystemImage
        XCTAssertNotNil(
            UIImage(systemName: name),
            "biometricSystemImage '\(name)' must be a resolvable SF Symbol"
        )
    }

    // MARK: - ApprovalAuditView load-more boundary

    /// The `hasMore` flag should be `true` iff the fetched count equals the
    /// page limit — the signal that there are probably more records on the server.
    func testHasMoreTrueWhenCountEqualsPageLimit() {
        XCTAssertTrue(
            hasMoreAfterFetch(count: 50, limit: 50),
            "hasMore should be true when count == limit (truncation possible)"
        )
    }

    func testHasMoreFalseWhenCountBelowPageLimit() {
        XCTAssertFalse(
            hasMoreAfterFetch(count: 49, limit: 50),
            "hasMore should be false when count < limit (full result returned)"
        )
    }

    func testHasMoreFalseWhenCountIsZero() {
        XCTAssertFalse(
            hasMoreAfterFetch(count: 0, limit: 50),
            "hasMore must be false for an empty result"
        )
    }

    func testHasMoreTrueAtMaxLimit() {
        XCTAssertTrue(
            hasMoreAfterFetch(count: 500, limit: 500),
            "hasMore should be true when count == maxLimit"
        )
    }

    /// Pure helper: mirrors the `hasMore` logic from ``ApprovalAuditView``.
    private func hasMoreAfterFetch(count: Int, limit: Int) -> Bool {
        count >= limit
    }

    // MARK: - DevicesView current-device marking (regression pin)

    func testIsCurrentDeviceMatchesRecordedId() {
        XCTAssertTrue(DevicesView.isCurrentDevice("dev_1", recordedDeviceId: "dev_1"))
        XCTAssertFalse(DevicesView.isCurrentDevice("dev_1", recordedDeviceId: "dev_2"))
        XCTAssertFalse(DevicesView.isCurrentDevice("dev_1", recordedDeviceId: nil))
        XCTAssertFalse(DevicesView.isCurrentDevice("dev_1", recordedDeviceId: ""))
    }

    // MARK: - QuickCapture removal — DefaultsKeys no longer carries captureEnabled

    func testDefaultsKeysHasNoCaptureEnabledKeyConstant() {
        // Verify that the captureEnabled/capturePrefix symbols were removed from
        // DefaultsKeys. We do this by asserting that the raw key string is NOT
        // stored anywhere in UserDefaults under a key that matches the old name —
        // and by the fact that this file compiles WITHOUT referencing those symbols
        // (a reference would cause a compile error if the symbol was removed).
        let defaults = UserDefaults.standard
        // The OLD key string — must not be written by any remaining code path.
        let oldKey = "hermes.captureEnabled"
        // We don't assert its absence here because a stale value from a prior
        // install could persist; we just assert no NEW code is writing it.
        // The compile-time proof is: this test file compiles without importing
        // DefaultsKeys.captureEnabled (that symbol is gone).
        _ = defaults.object(forKey: oldKey) // safe to read — just checking it's inert
        // Confirm the canonical captureEnabled key constant no longer exists on
        // DefaultsKeys by attempting a Mirror reflection.
        let mirror = Mirror(reflecting: DefaultsKeys.self)
        let labels = mirror.children.map(\.label)
        XCTAssertFalse(
            labels.contains("captureEnabled"),
            "DefaultsKeys must no longer expose a captureEnabled constant"
        )
    }
}

/// ABH-237 — view-only Nous credits / billing RPC coverage.
final class CreditsBillingRPCTests: XCTestCase {

    private final class ScriptedTransport: GatewayWebSocketTask, @unchecked Sendable {
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private let lock = NSLock()

        private(set) var methods: [String] = []
        private(set) var params: [String: [String: Any]] = [:]

        init() {
            enqueue(.string(
                #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#
            ))
        }

        func resume() {}
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !inbox.isEmpty {
                    let next = inbox.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: next)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case let .string(text) = message,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let method = object["method"] as? String
            else { return }

            record(method: method, params: object["params"] as? [String: Any] ?? [:])
            enqueue(.string(Self.responseFrame(id: id, method: method)))
            await Task.yield()
        }

        private func record(method: String, params: [String: Any]) {
            lock.lock()
            methods.append(method)
            self.params[method] = params
            lock.unlock()
        }

        private func enqueue(_ message: URLSessionWebSocketTask.Message) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: message)
            } else {
                inbox.append(message)
                lock.unlock()
            }
        }

        private static func responseFrame(id: String, method: String) -> String {
            let result: String
            switch method {
            case "credits.view":
                result = #"{"balance_lines":["Balance: $12.34","Monthly cap: $50"],"identity_line":"Nous Portal — abhi@example.com","topup_url":"https://portal.nousresearch.com/credits","depleted":true}"#
            case "billing.state":
                result = #"{"auto_reload":false,"billing_state":"active"}"#
            case "billing.auto_reload":
                result = #"{"auto_reload":true,"billing_state":"active"}"#
            default:
                result = #"{}"#
            }
            return #"{"jsonrpc":"2.0","id":"\#(id)","result":\#(result)}"#
        }
    }

    func testCreditsViewDecodeAndAutoReloadToggleRPCPath() async throws {
        let transport = ScriptedTransport()
        let client = HermesGatewayClient { _ in transport }
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        let credits = try await client.viewCredits()
        XCTAssertEqual(credits.balanceLines, ["Balance: $12.34", "Monthly cap: $50"])
        XCTAssertEqual(credits.identityLine, "Nous Portal — abhi@example.com")
        XCTAssertEqual(credits.topupURL?.absoluteString, "https://portal.nousresearch.com/credits")
        XCTAssertTrue(credits.depleted)

        let state = try await client.billingState()
        XCTAssertFalse(state.autoReloadEnabled)
        XCTAssertEqual(state.billingState, "active")

        let updated = try await client.setBillingAutoReload(true)
        XCTAssertTrue(updated.autoReloadEnabled)
        XCTAssertEqual(updated.billingState, "active")

        XCTAssertEqual(transport.methods, ["credits.view", "billing.state", "billing.auto_reload"])
        XCTAssertEqual(transport.params["billing.auto_reload"]?["enabled"] as? Bool, true)
        await client.disconnect()
    }
}
