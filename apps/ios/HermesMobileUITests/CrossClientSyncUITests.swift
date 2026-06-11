import XCTest

/// Proves multi-client live sync (HERMES_GATEWAY_BROADCAST=1): the app views
/// a session while a SECOND client — this test runner, over its own raw
/// WebSocket — resumes the same stored session and submits a prompt. The
/// app must render the streamed reply it never asked for.
final class CrossClientSyncUITests: XCTestCase {

    func testForeignTurnIsMirroredLive() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !base.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        // 1. Foreign client (playing the desktop) creates a session and runs a
        //    first turn so the stored row materializes in session.list.
        //    (A freshly created session only appears in the list after its
        //    first message persists.)
        let foreign = ForeignClient(base: base, token: token)
        try foreign.connect()
        defer { foreign.close() }
        let runtime = try foreign.createSession()
        try foreign.submitPrompt(sessionId: runtime, text: "Reply with exactly: HELLO-FROM-DESKTOP")
        try foreign.waitForTurnComplete(sessionId: runtime, timeout: 120)

        // 2. App launches on a draft chat (Batch B chat-as-home); open the drawer
        //    and tap the foreign session's row to resume it.
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launch()

        // Connected chat shell rendered → open the navigation drawer.
        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (draft home) did not appear"
        )
        drawerToggle.tap()

        // The foreign session row appears in the drawer list (the list refreshes
        // over REST after connect). Tap it to open/resume.
        let firstRow = app.descendants(matching: .any)
            .matching(identifier: "sessionRow").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "Drawer session row missing")
        firstRow.tap()
        // Resume finished once the prior transcript is visible.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "HELLO-FROM-DESKTOP")
            ).firstMatch.waitForExistence(timeout: 60),
            "Resumed transcript did not load"
        )

        // 3. Foreign client drives the NEXT turn while the app watches.
        try foreign.submitPrompt(
            sessionId: runtime,
            text: "Reply with exactly the word MIRRORTEST and nothing else."
        )

        // 3a. CLASSIFY the failure surface. The foreign turn runs a real model
        //     server-side; until its `message.complete` lands on the foreign WS
        //     there is *nothing* for the app to mirror. Waiting here on the
        //     foreign client's own socket (independent of the app's socket)
        //     separates "the turn never finished server-side" (a backend/model
        //     problem — NOT a mirror bug) from "the turn finished but the app
        //     failed to render it" (the actual cross-client mirror property).
        //     Generous ceiling: a cold agent spin-up + model generation can be
        //     slow, and that is not what this test is meant to police.
        let submitInstant = Date()
        do {
            try foreign.waitForTurnComplete(sessionId: runtime, timeout: 180)
        } catch {
            let elapsed = Date().timeIntervalSince(submitInstant)
            XCTFail(
                "foreign turn never completed server-side (backend/model issue) "
                + "— NOT a mirror failure: no message.complete on the foreign "
                + "client within 180s (waited \(String(format: "%.1f", elapsed))s); "
                + "underlying: \(error.localizedDescription)"
            )
            return
        }
        let completeInstant = Date()
        let turnSeconds = completeInstant.timeIntervalSince(submitInstant)
        let turnAttachment = XCTAttachment(
            string: "foreign message.complete observed "
            + "\(String(format: "%.2f", turnSeconds))s after 2nd submit"
        )
        turnAttachment.name = "foreign-turn-complete-seconds"
        turnAttachment.lifetime = .keepAlways
        add(turnAttachment)

        // 3b. The foreign turn is now PROVEN complete server-side, so a real
        //     mirror renders promptly: deltas stream during the turn (40ms
        //     coalesce) and `message.complete` triggers a REST backfill. A
        //     short budget is therefore sufficient; if MIRRORTEST is still
        //     absent the turn DID finish but the app dropped it — a genuine
        //     app/server mirror bug, not a slow model.
        let mirrored = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "MIRRORTEST")
        ).firstMatch
        let mirrorRendered = mirrored.waitForExistence(timeout: 15)
        let mirrorLag = Date().timeIntervalSince(completeInstant)
        let lagAttachment = XCTAttachment(
            string: "mirror UI assertion resolved "
            + "\(String(format: "%.2f", mirrorLag))s after foreign "
            + "message.complete (rendered=\(mirrorRendered))"
        )
        lagAttachment.name = "mirror-lag-seconds"
        lagAttachment.lifetime = .keepAlways
        add(lagAttachment)

        XCTAssertTrue(
            mirrorRendered,
            "MIRROR BUG: foreign turn COMPLETED server-side "
            + "(\(String(format: "%.1f", turnSeconds))s) but its text was not "
            + "mirrored into the app UI within 15s — the turn finished, the app "
            + "dropped/never-rendered the frame (app/server mirror defect, NOT a "
            + "slow model)"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "cross-client-mirror"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Minimal synchronous JSON-RPC-over-WebSocket client for the test runner.
private final class ForeignClient {
    private let wsTask: URLSessionWebSocketTask
    private var nextId = 0

    init(base: String, token: String) {
        var components = URLComponents(string: base)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.setValue("127.0.0.1", forHTTPHeaderField: "Host")
        wsTask = URLSession.shared.webSocketTask(with: request)
    }

    func connect() throws {
        wsTask.resume()
        _ = try receiveFrame(timeout: 15) // gateway.ready
    }

    func close() {
        wsTask.cancel(with: .normalClosure, reason: nil)
    }

    func createSession() throws -> String {
        let result = try request(
            method: "session.create",
            params: ["cols": 96],
            timeout: 120
        )
        guard let runtime = result["session_id"] as? String else {
            throw NSError(domain: "ForeignClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "session.create returned no session_id",
            ])
        }
        return runtime
    }

    /// Drain inbound frames until `message.complete` arrives for *sessionId*.
    func waitForTurnComplete(sessionId: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let obj = try receiveFrame(timeout: deadline.timeIntervalSinceNow),
                  obj["method"] as? String == "event",
                  let params = obj["params"] as? [String: Any],
                  params["session_id"] as? String == sessionId,
                  params["type"] as? String == "message.complete"
            else { continue }
            return
        }
        throw NSError(domain: "ForeignClient", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "timeout waiting for message.complete",
        ])
    }

    func submitPrompt(sessionId: String, text: String) throws {
        _ = try request(
            method: "prompt.submit",
            params: ["session_id": sessionId, "text": text]
        )
    }

    // MARK: - Plumbing

    private func request(
        method: String,
        params: [String: Any],
        timeout: TimeInterval = 30
    ) throws -> [String: Any] {
        nextId += 1
        let id = "t\(nextId)"
        let frame: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        let sendDone = expectation(description: "send")
        wsTask.send(.string(String(data: data, encoding: .utf8)!)) { _ in
            sendDone.fulfill()
        }
        XCTWaiter().wait(for: [sendDone], timeout: 10)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let obj = try receiveFrame(timeout: deadline.timeIntervalSinceNow) else { continue }
            if let frameId = obj["id"] as? String, frameId == id {
                if let error = obj["error"] as? [String: Any] {
                    throw NSError(domain: "ForeignClient", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "\(method): \(error["message"] ?? "rpc error")",
                    ])
                }
                return (obj["result"] as? [String: Any]) ?? [:]
            }
            // Events and other clients' frames: ignore, keep waiting.
        }
        throw NSError(domain: "ForeignClient", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "timeout waiting for \(method) response",
        ])
    }

    private func receiveFrame(timeout: TimeInterval) throws -> [String: Any]? {
        let done = expectation(description: "recv")
        var received: String?
        var failure: Error?
        wsTask.receive { result in
            switch result {
            case .success(.string(let text)): received = text
            case .success(.data(let data)): received = String(data: data, encoding: .utf8)
            case .success: break
            case .failure(let error): failure = error
            }
            done.fulfill()
        }
        let outcome = XCTWaiter().wait(for: [done], timeout: max(timeout, 1))
        if outcome != .completed { return nil }
        if let failure { throw failure }
        guard let received, let data = received.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func expectation(description: String) -> XCTestExpectation {
        XCTestExpectation(description: description)
    }
}
