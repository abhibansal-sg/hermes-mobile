import XCTest

/// Proves multi-client live sync (HERMES_GATEWAY_BROADCAST=1): the app views
/// a session while a SECOND client — this test runner, over its own raw
/// WebSocket — resumes the same stored session and submits a prompt. The
/// app must render the streamed reply it never asked for.
final class CrossClientSyncUITests: XCTestCase {

    func testExternallyDrivenForeignTurnIsMirroredLive() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let marker = env["HERMES_LIVE_FOLLOW_MARKER"],
              !base.isEmpty, !token.isEmpty, !marker.isEmpty else {
            throw XCTSkip("live gateway credentials/marker not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchEnvironment["HERMES_TRANSPORT"] = "gatewayDirect"
        app.launchArguments += ["-hermes.transportPath", "gatewayDirect"]
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
        drawerToggle.tap()

        let ownedSession = app.buttons.matching(identifier: "sessionRow")
            .matching(NSPredicate(format: "label BEGINSWITH %@", marker)).firstMatch
        XCTAssertTrue(ownedSession.waitForExistence(timeout: 20))
        ownedSession.tap()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", marker + "-FIRST")
            ).firstMatch.waitForExistence(timeout: 60),
            "Externally owned session did not paint its first turn"
        )
        let secondReply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", marker + "-SECOND")
        ).firstMatch
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let redundantPush = springboard.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", marker + "-SECOND")
        ).firstMatch

        print("ABH519_WATCH_READY")

        let deadline = Date().addingTimeInterval(120)
        while !secondReply.exists, Date() < deadline {
            XCTAssertFalse(
                redundantPush.exists,
                "Foreground phone received a redundant completion push"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(
            secondReply.exists,
            "Foreign turn completed but was not mirrored into the watching phone"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "cross-client-mirror-physical"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertFalse(
            redundantPush.exists,
            "Foreground phone received a redundant completion push"
        )
    }

    func testExternallyDrivenSessionRepaintsAfterForceClose() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let marker = env["HERMES_LIVE_FOLLOW_MARKER"],
              !base.isEmpty, !token.isEmpty, !marker.isEmpty else {
            throw XCTSkip("live gateway credentials/marker not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["--uitest-mute-audio"]

        func openSeededSession() {
            app.launch()
            let drawerToggle = app.buttons["drawerToggle"]
            XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
            drawerToggle.tap()
            let ownedSession = app.buttons.matching(identifier: "sessionRow")
                .matching(NSPredicate(format: "label BEGINSWITH %@", marker)).firstMatch
            XCTAssertTrue(ownedSession.waitForExistence(timeout: 20))
            ownedSession.tap()
        }

        let secondMarker = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", marker + "-SECOND")
        ).firstMatch
        openSeededSession()
        XCTAssertTrue(secondMarker.waitForExistence(timeout: 30))

        app.terminate()
        openSeededSession()
        XCTAssertTrue(
            secondMarker.waitForExistence(timeout: 10),
            "Force-close/reopen did not repaint the stored transcript"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "stored-transcript-force-close-repaint"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStockLoadEarlierPreservesActiveTurn() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let title = env["HERMES_PAGINATION_TITLE"],
              !base.isEmpty, !token.isEmpty, !title.isEmpty else {
            throw XCTSkip("live gateway credentials/pagination fixture not provided")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launchEnvironment["HERMES_TRANSPORT"] = "gatewayDirect"
        app.launchArguments += ["-hermes.transportPath", "gatewayDirect"]
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
        drawerToggle.tap()
        let row = app.buttons.matching(identifier: "sessionRow")
            .matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "seeded stock session missing")
        row.tap()

        XCTAssertTrue(app.textFields["Message Hermes…"].waitForExistence(timeout: 30)
            || app.textViews["Message Hermes…"].waitForExistence(timeout: 3))

        let field = app.textFields["Message Hermes…"]
        let textView = app.textViews["Message Hermes…"]
        let composer = field.exists ? field : textView
        composer.tap()
        composer.typeText(
            "Use the terminal to run sleep 120. Then reply with the uppercase form "
                + "of the words 'pagination survived' and nothing else."
        )
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Interrupt"].waitForExistence(timeout: 30))

        func swipeTowardEarlier() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68)
                    )
                )
        }
        for _ in 0..<12 { swipeTowardEarlier() }
        let loadEarlier = app.buttons["loadEarlierMessages"]
        XCTAssertTrue(loadEarlier.waitForExistence(timeout: 10), "Load Earlier missing")
        // The first tap reveals the remainder of the already-loaded 50-row
        // window; the second must cross the server boundary and fetch page 2.
        loadEarlier.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        for _ in 0..<3 { swipeTowardEarlier() }
        XCTAssertTrue(loadEarlier.waitForExistence(timeout: 5), "server page affordance missing")
        loadEarlier.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        swipeTowardEarlier()
        let olderPageMarker = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "pagination fixture message 070")
        ).firstMatch
        XCTAssertTrue(olderPageMarker.waitForExistence(timeout: 10), "stock page 2 was not applied")
        XCTAssertTrue(app.buttons["Interrupt"].exists, "page load discarded the active turn")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "stock-pagination-during-active-turn"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Interrupt"].tap()
    }

    func testDesktopCompletionPushOpensOwningSession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let marker = env["HERMES_LIVE_FOLLOW_MARKER"],
              !base.isEmpty, !token.isEmpty, !marker.isEmpty else {
            throw XCTSkip("live gateway credentials/marker not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()
        XCTAssertTrue(app.buttons["drawerToggle"].waitForExistence(timeout: 30))

        XCUIDevice.shared.press(.home)
        print("ABH519_PUSH_READY")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notification = springboard.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", marker + "-COMPLETE")
        ).firstMatch
        XCTAssertTrue(
            notification.waitForExistence(timeout: 180),
            "Desktop completion did not produce a phone notification"
        )
        notification.tap()

        XCTAssertTrue(app.buttons["drawerToggle"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", marker + "-COMPLETE")
            ).firstMatch.waitForExistence(timeout: 30),
            "Completion notification did not open its owning transcript"
        )
        XCTAssertTrue(
            springboard.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", marker + "-COMPLETE")
            ).firstMatch.waitForNonExistence(timeout: 8),
            "Completion produced more than one phone notification"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "desktop-completion-push-opened-session"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDesktopClarificationPushOpensOwningGate() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let marker = env["HERMES_LIVE_FOLLOW_MARKER"],
              !base.isEmpty, !token.isEmpty, !marker.isEmpty else {
            throw XCTSkip("live gateway credentials/marker not provided; skipping live test")
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()
        XCTAssertTrue(app.buttons["drawerToggle"].waitForExistence(timeout: 30))

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        print("ABH519_CLARIFY_PUSH_READY")

        // Notification Summaries may rewrite visible text, but SpringBoard's
        // notification button retains the original body in its accessibility
        // label. Select by the unique marker so an older alert cannot win.
        let notification = springboard.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", marker + "-QUESTION")
        ).firstMatch
        if !notification.waitForExistence(timeout: 15) {
            // A grouped alert can go straight to Notification Center without a
            // persistent banner. Pull down from the top edge and use the stored
            // notification instead of treating presentation timing as delivery.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                .press(
                    forDuration: 0.1,
                    thenDragTo: springboard.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)
                    )
                )
        }
        guard notification.waitForExistence(timeout: 15) else {
            XCTFail("Desktop clarification did not produce a phone notification")
            return
        }
        notification.tap()

        XCTAssertTrue(app.buttons["drawerToggle"].waitForExistence(timeout: 30))
        let clarificationCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Clarification request")
        ).firstMatch
        guard clarificationCard.waitForExistence(timeout: 30) else {
            XCTFail("Clarification notification did not open its owning gate")
            return
        }
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", marker + "-QUESTION")
            ).firstMatch.waitForExistence(timeout: 10),
            "Clarification notification opened a stale or foreign gate"
        )
        let leftChoice = app.buttons["Left"]
        guard leftChoice.waitForExistence(timeout: 10) else {
            XCTFail("Clarification gate did not expose its Left choice")
            return
        }
        leftChoice.tap()
        XCTAssertTrue(
            clarificationCard.waitForNonExistence(timeout: 30),
            "Clarification card did not clear after answering"
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", marker + "-ANSWERED")
            ).firstMatch.waitForExistence(timeout: 180),
            "Clarification answer did not reach the blocked agent and complete the turn"
        )
        XCTAssertTrue(
            notification.waitForNonExistence(timeout: 8),
            "Clarification produced more than one phone notification"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "desktop-clarification-push-opened-owning-gate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
        app.launchArguments += ["--uitest-mute-audio"]
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
            app.descendants(matching: .any).matching(
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
        let mirrored = app.descendants(matching: .any).matching(
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
        guard let ready = try receiveFrame(timeout: 15),
              ready["method"] as? String == "event",
              let params = ready["params"] as? [String: Any],
              params["type"] as? String == "gateway.ready" else {
            throw NSError(domain: "ForeignClient", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "gateway.ready not received",
            ])
        }
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
            params: [
                "session_id": sessionId,
                "text": text,
                "client_message_id": UUID().uuidString.lowercased(),
            ]
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
