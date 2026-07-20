import XCTest
import SwiftUI
import UIKit
@testable import HermesMobile

/// QA-2 A4/A6 + C1/C2 (fix round) — VISUAL EVIDENCE for the native chrome
/// rebuild.
///
/// The R7-R10 cards lane and the R12/R13 taskdock lane are pinned
/// structurally (ClarifyCardNativeTests, TaskDockLifecycleTests, TurnDockTests)
/// but C1 ("indistinguishable from native") and C2 ("nothing wider than the
/// composer") are OWNER VISUAL acceptance criteria, and A4 requires screenshot
/// evidence vs the 02:2x complaint images (IMG_2529-2576). These tests render
/// the EXACT production views (`ClarifyBanner`, `ApprovalCard`, `TurnDock`)
/// through `ImageRenderer` and write PNGs into the QA-2 evidence dir
/// (`evidence/daily-driver-qa2/cards/` by default; override with
/// `EVIDENCE_SNAPSHOT_DIR`).
///
/// Deterministic: no network, no live gateway/relay (hard rules). The views
/// are fed the same payload shapes the render-conformance fixtures carry.
/// Fidelity note: `glassEffect` blur is rasterized against the in-tree chat
/// backdrop (ImageRenderer has no live window backdrop); final visual sign-off
/// is the device install (A11).
@MainActor
final class NativeChromeSnapshotEvidenceTests: XCTestCase {

    // MARK: - Harness

    private var evidenceDir: URL {
        let path = ProcessInfo.processInfo.environment["EVIDENCE_SNAPSHOT_DIR"]
            ?? "/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa2/cards"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Render `view` at a fixed content width (default 360pt ≈ the chat column
    /// on an iPhone Air minus gutters) and write a 3x PNG to the evidence dir.
    private func snapshot<V: View>(_ view: V, name: String, width: CGFloat = 360) throws {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 3
        guard let image = renderer.uiImage, let png = image.pngData() else {
            XCTFail("ImageRenderer produced no image for \(name)")
            return
        }
        let out = evidenceDir.appendingPathComponent("\(name).png")
        try png.write(to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "evidence PNG written: \(out.path)")
    }

    /// A minimal chat-column backdrop (theme bg + two faux transcript rows) so
    /// the glass surface has real content behind it to blur — mirrors how the
    /// cards sit over the live turn stack, and lets the C2 "nothing wider than
    /// the composer" framing read in the PNG.
    private func chatBackdrop(_ theme: HermesTheme, @ViewBuilder chrome: () -> some View) -> some View {
        ZStack(alignment: .top) {
            theme.bg
            VStack(alignment: .leading, spacing: 10) {
                Text("Ran the migration and the smoke suite.")
                    .font(.body)
                    .foregroundStyle(theme.cardFg)
                    .padding(12)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("One thing needs your call before I deploy.")
                    .font(.body)
                    .foregroundStyle(theme.cardFg)
                    .padding(12)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                chrome()
                    .padding(.top, 6)
                // Faux composer so the "nothing wider than the composer"
                // contract (C2) is visible in-frame.
                HStack {
                    Text("Message Hermes…")
                        .font(.body)
                        .foregroundStyle(theme.mutedFg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(theme.input, in: Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .environment(\.hermesTheme, theme)
    }

    private func clarifyPayload(question: String, choices: [String], id: String) -> PendingClarification {
        PendingClarification(
            sessionId: "session-evidence",
            request: ClarifyRequestPayload(payload: .object([
                "question": .string(question),
                "choices": .array(choices.map { .string($0) }),
                "request_id": .string(id),
            ]))
        )
    }

    // MARK: - A4 — clarify card, native (R7/C1), typical question (dark + light)

    func testSnapshotClarifyCardNativeDark() throws {
        let card = ClarifyBanner(
            clarification: clarifyPayload(
                question: "Deploy to production now, or cut a staging build first?",
                choices: ["Deploy to production", "Staging first", "Hold"],
                id: "snap-1"),
            chatStore: ChatStore()
        )
        try snapshot(
            chatBackdrop(HermesThemePresets.nousDark) { card },
            name: "qa2-clarify-card-native-dark"
        )
    }

    func testSnapshotClarifyCardNativeLight() throws {
        let card = ClarifyBanner(
            clarification: clarifyPayload(
                question: "Deploy to production now, or cut a staging build first?",
                choices: ["Deploy to production", "Staging first", "Hold"],
                id: "snap-2"),
            chatStore: ChatStore()
        )
        try snapshot(
            chatBackdrop(HermesThemePresets.nousLight) { card },
            name: "qa2-clarify-card-native-light"
        )
    }

    // MARK: - A4 — clarify card, long text wraps + bounded (R10)

    func testSnapshotClarifyCardLongText() throws {
        let longChoice = String(
            repeating: "Rebuild the on-device cache with the v4 schema and backfill from the relay mirror ",
            count: 2)
        let longQuestion = String(
            repeating: "Before I continue I need to know which migration strategy you want for the offline cache. ",
            count: 6)
        let card = ClarifyBanner(
            clarification: clarifyPayload(
                question: longQuestion,
                choices: [longChoice, "Keep the current schema and patch rows in place"],
                id: "snap-3"),
            chatStore: ChatStore()
        )
        try snapshot(
            chatBackdrop(HermesThemePresets.nousDark) { card },
            name: "qa2-clarify-card-longtext"
        )
    }

    // MARK: - A4 — approval card, native (R7/C1)

    func testSnapshotApprovalCardNative() throws {
        let approval = PendingApproval(
            id: "appr-snap-1",
            sessionId: "session-evidence",
            request: ApprovalRequestPayload(payload: .object([
                "approval_id": .string("appr-snap-1"),
                "command": .string("rm -rf build/ && swift build -c release"),
                "description": .string("Wipe the build directory and rebuild release artifacts before packaging."),
                "target": .string("server: prod-1 (relay host)"),
                "action": .string("shell"),
                "pattern_key": .string("rm_rf"),
            ]))
        )
        let card = ApprovalCard(approval: approval, chatStore: ChatStore())
        try snapshot(
            chatBackdrop(HermesThemePresets.nousDark) { card },
            name: "qa2-approval-card-native"
        )
    }

    // MARK: - A6 — task dock: task pill + pending pill side-by-side (R12/C2)

    /// The owner's exact R12 redesign requirement: when a task list AND a
    /// queued backlog are both live, the task capsule and the pending capsule
    /// sit SIDE-BY-SIDE in one CENTERED width-to-fit row — never full-width.
    func testSnapshotTaskDockTaskPlusPendingPills() async throws {
        let chat = liveTurnChatWithTasks()
        let (queue, directory) = try await makeQueue(pendingTexts: ["Also ping the on-call channel"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let dock = TurnDock(chatStore: chat, queueStore: queue, themeStore: ThemeStore())
        try snapshot(
            chatBackdrop(HermesThemePresets.nousDark) { dock },
            name: "qa2-dock-task-plus-pending"
        )
    }

    /// Task pill alone: a native capsule, width-to-fit and centered above the
    /// composer (C2 — never the old full-width floating box).
    func testSnapshotTaskDockTaskPillOnly() async throws {
        let chat = liveTurnChatWithTasks()
        // Empty outbox → the queued capsule is absent; the task capsule
        // renders alone, centered.
        let (queue, directory) = try await makeQueue(pendingTexts: [])
        defer { try? FileManager.default.removeItem(at: directory) }

        let dock = TurnDock(chatStore: chat, queueStore: queue, themeStore: ThemeStore())
        try snapshot(
            chatBackdrop(HermesThemePresets.nousDark) { dock },
            name: "qa2-dock-task-pill-only"
        )
    }

    // MARK: - State builders (same shapes the lane tests use)

    /// A ChatStore mid-turn (isStreaming) carrying a non-terminal todo list —
    /// the exact gate `dockShowsTaskBox` requires (turn-lifecycle-driven,
    /// owner nil↔nil pass) so the dock surface is live.
    private func liveTurnChatWithTasks() -> ChatStore {
        let chat = ChatStore()
        let todosJSON = #"""
        {"todos":[{"id":"1","content":"Read auth.py","status":"completed"},
                  {"id":"2","content":"Run migration 35","status":"in_progress"},
                  {"id":"3","content":"Open a PR","status":"pending"}]}
        """#
        let data = Data(todosJSON.utf8)
        let decoded = try! JSONDecoder().decode(JSONValue.self, from: data)
        let tool = ToolActivity(
            id: "todo-evidence", name: TodoList.toolName, argsSummary: "", progressText: "",
            resultPreview: "", state: .running, durationMs: nil,
            todos: decoded["todos"]!.arrayValue!
        )
        chat.messages = [ChatMessage(role: .assistant, parts: [
            .tools(id: "cluster-evidence", tools: [tool], collapsed: false, turnElapsed: 42)
        ])]
        chat.isStreaming = true
        return chat
    }

    /// Real WorkRepository + QueueStore (same construction as
    /// OutboxScopingTests), seeded with `pendingTexts` queued prompts bound to
    /// a nil session so the draft composer's projection (`activeItems`) — and
    /// therefore the dock's queued capsule — sees them.
    private func makeQueue(pendingTexts: [String]) async throws -> (QueueStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotDock-\(UUID().uuidString)", isDirectory: true)
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: observation
        )
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        let queue = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope }
        )
        for text in pendingTexts {
            _ = try await repository.enqueue(WorkJobInput(
                kind: .prompt, scope: scope, state: .queued, text: text, storedSessionID: nil
            ))
        }
        return (queue, directory)
    }
}
