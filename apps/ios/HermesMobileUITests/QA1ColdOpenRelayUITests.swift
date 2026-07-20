import XCTest

/// QA-1 resume-lane evidence (A1/A7): FIVE consecutive COLD opens in relay mode
/// against the isolated (9130+) mock gateway + worktree relay — never the live
/// 9119 gateway. Asserts:
///   - zero modal alerts on every cold open (B1 north-star: the relay resume
///     queues on transport readiness and self-heals silently; the build-114
///     "Resume Session Failed" alert must never appear);
///   - composer interactive ≤2s of the shell rendering (A1);
///   - the cached transcript paints on the restored session's cold opens (the
///     B4 blank-screen class is absent: cache → skeleton → content, never void);
///   - the drawer closes on a session tap (B3/A7).
///
/// The backend is brought up by `scripts/qa1-cold-open-evidence.sh` (mock
/// gateway + real relay subprocess) which exports the TEST_RUNNER_* env the
/// runner surfaces here; the test SKIPS when they are absent so the suite stays
/// green without a backend.
@MainActor
final class QA1ColdOpenRelayUITests: XCTestCase {
    private let composerPlaceholder = "Message Hermes…"
    private let closeDeadline: TimeInterval = 1.0

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 400
    }

    func testFiveColdOpensZeroAlertsAndInstantPaint() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let relayURL = env["HERMES_RELAY_URL"],
              !url.isEmpty, !token.isEmpty, !relayURL.isEmpty else {
            throw XCTSkip(
                "HERMES_URL/HERMES_TOKEN/HERMES_RELAY_URL not provided — start the isolated backend via scripts/qa1-cold-open-evidence.sh"
            )
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        // Relay transport (DEBUG env override) + the isolated relay to dial.
        app.launchEnvironment["HERMES_TRANSPORT"] = "relay"
        app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        app.launchEnvironment["HERMES_UITEST_SIZE_CLASS"] = "compact"
        app.launchArguments += ["--uitest-mute-audio", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addSystemAlertMonitor()

        var evidence: [String] = []
        for iteration in 1...5 {
            app.launch()  // terminate() at the loop tail ⇒ every iteration is a COLD open

            // 1. Chat shell renders (A1).
            let shellStart = Date()
            let drawerToggle = app.buttons["drawerToggle"]
            XCTAssertTrue(
                drawerToggle.waitForExistence(timeout: 20),
                "cold open \(iteration): connected chat shell did not render"
            )

            // 2. Composer interactive ≤2s of the shell (A1).
            let composer = composerElement(app)
            let composerOK = composer.waitForExistence(timeout: 2)
            let shellToComposer = Date().timeIntervalSince(shellStart)
            XCTAssertTrue(
                composerOK,
                "cold open \(iteration): composer not interactive within 2s of the shell (took \(String(format: "%.2f", shellToComposer))s)"
            )

            // 3. ZERO modal alerts (B1). A racing relay resume gets a moment to
            //    surface any (regression) alert, then none must exist.
            let alert = app.alerts.firstMatch
            let alertAppeared = alert.waitForExistence(timeout: 1.5)
            XCTAssertFalse(
                alertAppeared,
                "cold open \(iteration): modal alert present: \(alert.label)"
            )

            if iteration == 1 {
                // Create a settled session over the relay so the remaining cold
                // opens restore a pre-selected session — the exact condition
                // that tripped the build-114 cold-start resume alert.
                composer.tap()
                composer.typeText("qa1 cold open probe")
                let send = app.buttons["Send"]
                XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button missing")
                send.tap()
                let reply = app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS[c] %@", "Paris")
                ).firstMatch
                XCTAssertTrue(
                    reply.waitForExistence(timeout: 45),
                    "scripted echo reply did not land on the relay path"
                )
                // Open the new session from the drawer so the cold cache
                // restore on the next launches PRE-SELECTS it (the exact
                // condition that tripped the build-114 cold-start resume
                // alert): the tap persists `lastOpenedSession` and seeds the
                // transcript cache via the relay history fetch.
                drawerToggle.tap()
                let row = app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "sessionRow.")
                ).firstMatch
                XCTAssertTrue(
                    row.waitForExistence(timeout: 45),
                    "the relay-created session never surfaced in the drawer"
                )
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let avatar = app.buttons["settingsAvatar"]
                XCTAssertTrue(
                    waitUntil(timeout: closeDeadline) { !avatar.isHittable },
                    "open1: drawer stayed open after session tap"
                )
                // Let the open's persistence + cache write-through settle.
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.5))
                evidence.append("open1: shellToComposer=\(String(format: "%.2f", shellToComposer))s turn=settled session=opened")
            } else {
                // 4. Cache paint: the settled transcript must be visible quickly
                //    (B4 — no blank screen; B2 — no skeleton-forever).
                let cached = app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS[c] %@", "Paris")
                ).firstMatch
                let cachePainted = cached.waitForExistence(timeout: 3)
                XCTAssertTrue(
                    cachePainted,
                    "cold open \(iteration): cached transcript did not paint (blank/skeleton screen)"
                )

                // 5. Drawer closes on session tap (B3/A7).
                drawerToggle.tap()
                let row = app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "sessionRow.")
                ).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5), "cold open \(iteration): no session row in drawer")
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let avatar = app.buttons["settingsAvatar"]
                XCTAssertTrue(
                    waitUntil(timeout: closeDeadline) { !avatar.isHittable },
                    "cold open \(iteration): drawer stayed open after session tap"
                )
                evidence.append(
                    "open\(iteration): shellToComposer=\(String(format: "%.2f", shellToComposer))s cachePaint=\(cachePainted) alert=\(alertAppeared) drawerClosed=true"
                )
            }

            app.terminate()
        }
        NSLog("QA1-COLD-OPEN-EVIDENCE: \(evidence.joined(separator: " | "))")
    }

    // MARK: - Helpers

    /// The composer field is exposed as a TextField or a TextView depending on
    /// the axis (mirrors ChatFlowUITests); accept either.
    private func composerElement(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields[composerPlaceholder]
        return field.exists ? field : app.textViews[composerPlaceholder]
    }

    private func addSystemAlertMonitor() {
        addUIInterruptionMonitor(withDescription: "Dismiss simulator system alerts") { alert in
            for title in ["Allow", "Cancel", "Don’t Allow", "Don't Allow", "OK"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return condition()
    }
}
