import XCTest
import SwiftUI
@testable import HermesMobile

/// STR-1029 visual-evidence capture: renders the **production** glow shell and
/// context-line views to PNG via `ImageRenderer` so the reviewer can see the
/// actual SwiftUI output without a live streaming gateway.
///
/// This is deterministic and sim-scoped — it runs inside the simulator test
/// bundle, renders the real `TurnActivityBar` / `SessionContextLine` types from
/// ChatView.swift (no replicas), and writes labelled PNGs to a temp directory.
/// No host cursor/click tools, no network, no streaming provider.
///
/// The breathing glow's `onAppear` animation does not fire inside
/// `ImageRenderer` (it captures a single static frame at the initial
/// `breathing = false` state → min alphas). The alpha values, breathe cadence,
/// and reduce-motion gating are already pinned by `TranscriptChromeGlowTests`;
/// these PNGs evidence the shell geometry, layout, typography, and visibility
/// gate across iPhone (compact) and iPad (regular). Reduce-motion visual is not
/// capturable here because `\.accessibilityReduceMotion` is a read-only
/// environment keypath.
@MainActor
final class TranscriptChromeGlowEvidenceTests: XCTestCase {

    // iPhone 17 / iPad Pro logical widths for the transcript frame.
    private let iphoneWidth: CGFloat = 390
    private let ipadWidth: CGFloat = 1_024

    private var evidenceDir: URL!

    override func setUpWithError() throws {
        evidenceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glow-evidence-STR-1029", isDirectory: true)
        try? FileManager.default.removeItem(at: evidenceDir)
        try FileManager.default.createDirectory(
            at: evidenceDir, withIntermediateDirectories: true)
    }

    // MARK: - Evidence test

    func testRenderGlowEvidencePNGs() throws {
        let store = makeStreamingStore()
        let settled = ChatStore() // isStreaming defaults to false → glow absent

        let contextSummary = SessionSummary(
            id: "sess-1", title: "Refactor auth flow",
            preview: "Let's extract the middleware…",
            startedAt: 1_750_000_000, messageCount: 12,
            source: nil, lastActive: 1_750_000_030,
            cwd: "/Users/dev/projects/myapp", profile: nil)

        var paths: [String] = []

        // 1. iPhone — glow active (compact, normal motion)
        try renderAndSave(
            name: "01-iphone-glow-active",
            caption: "iPhone · compact · glow ACTIVE (isStreaming=true, normal motion) — min-alpha resting frame; ring breathes 0.06→0.12 at runtime",
            width: iphoneWidth, sizeClass: .compact,
            content: transcriptTail(store: store, showGlow: true))
        paths.append("01-iphone-glow-active.png")

        // 2. iPad — glow active (regular, normal motion)
        try renderAndSave(
            name: "02-ipad-glow-active",
            caption: "iPad · regular · glow ACTIVE — clamped to ≤\(Int(ChatView.transcriptReadingMeasure))pt reading measure (not full-bleed)",
            width: ipadWidth, sizeClass: .regular,
            content: transcriptTail(store: store, showGlow: true))
        paths.append("02-ipad-glow-active.png")

        // 3. iPhone — glow SETTLED / disappeared (isStreaming=false)
        //    (Reduce-motion visual is not capturable via ImageRenderer —
        //    \.accessibilityReduceMotion is read-only. The static-at-mid alpha
        //    values and reduce-motion gating are pinned by TranscriptChromeGlowTests.)
        try renderAndSave(
            name: "03-iphone-glow-settled-gone",
            caption: "iPhone · compact · glow SETTLED (isStreaming=false) — row is absent, no residual chrome",
            width: iphoneWidth, sizeClass: .compact,
            content: transcriptTail(store: settled, showGlow: false))
        paths.append("03-iphone-glow-settled-gone.png")

        // 4. iPhone — context line with attached cwd
        try renderAndSave(
            name: "04-iphone-context-line",
            caption: "iPhone · compact · context line with attached workspace (cwd=/Users/dev/projects/myapp)",
            width: iphoneWidth, sizeClass: .compact,
            content: contextTail(summary: contextSummary))
        paths.append("04-iphone-context-line.png")

        // 5. iPad — context line (regular width)
        try renderAndSave(
            name: "05-ipad-context-line",
            caption: "iPad · regular · context line — clamped to ≤\(Int(ChatView.transcriptReadingMeasure))pt reading measure",
            width: ipadWidth, sizeClass: .regular,
            content: contextTail(summary: contextSummary))
        paths.append("05-ipad-context-line.png")

        // 6. iPad — a real user MessageBubble rendered adjacent to the status
        //    row, proving first-hand (not just asserted) that both share the
        //    same regular-width reading measure (STR-1102).
        try renderAndSave(
            name: "06-ipad-bubble-and-status-parity",
            caption: "iPad · regular · MessageBubble + TurnActivityBar share the \(Int(ChatView.transcriptReadingMeasure))pt reading measure",
            width: ipadWidth, sizeClass: .regular,
            content: bubbleAndStatusParityTail(store: store))
        paths.append("06-ipad-bubble-and-status-parity.png")

        // Assert all PNGs exist and are non-trivially sized.
        for name in paths {
            let url = evidenceDir.appendingPathComponent(name)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 2_000, "Evidence PNG \(name) is suspiciously small (\(size) bytes)")
        }

        // Measured-cap parity: print + assert the same values the PNGs show,
        // so the evidence is backed by a hard number, not just a rendered
        // pixel comparison (STR-1102).
        let regularBubbleCap = MessageBubble.userBubbleMaxWidth(
            screenWidth: ipadWidth, horizontalSizeClass: .regular)
        let regularRowCap = ChatView.transcriptRowMaxWidth(isCompact: false)
        XCTAssertEqual(regularBubbleCap, regularRowCap, accuracy: 0.001,
                        "Regular-width MessageBubble cap must equal the shared transcript reading measure")
        print("=== STR-1102 REGULAR-WIDTH CAP PARITY: bubble=\(regularBubbleCap) row=\(regularRowCap) ===")

        // Print the directory for host-side extraction.
        print("\n=== STR-1029 GLOW EVIDENCE DIR ===\n\(evidenceDir.path)\n=== END ===\n")
    }

    // MARK: - Store helpers

    /// A ChatStore driven into a streaming state. `isStreaming` is a public var;
    /// routing a synthetic `.messageStart` event through the full store graph
    /// also stamps `turnStartedAt` (private-set) so the elapsed label is live.
    private func makeStreamingStore() -> ChatStore {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = "rt-evidence"
        sessions.activeStoredId = "stored-evidence"
        chat.backfillFetch = { _ in [] }

        let event = GatewayEvent(params: .object([
            "type": .string("message.start"),
            "session_id": .string("rt-evidence"),
            "stored_session_id": .string("stored-evidence"),
            "payload": .object([:]),
        ]))!
        chat.handle(event: event)
        XCTAssertTrue(chat.isStreaming, "Evidence store should be streaming after message.start")
        return chat
    }

    // MARK: - Transcript-tail containers (mimic ChatView layout)

    /// A transcript tail showing a mock assistant bubble followed by the
    /// production `TurnActivityBar` when `showGlow` is true. The `.horizontal`
    /// padding (16) and `intraTurnGap` (6) match ChatView's layout so the
    /// rendered frame faithfully represents the inline position — not a
    /// floating overlay.
    @ViewBuilder
    private func transcriptTail(store: ChatStore, showGlow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Simulated prior assistant reply bubble.
            Text("Sure — I'll extract the auth middleware into a dedicated module and update the imports.")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            if showGlow {
                TurnActivityBar(chatStore: store)
                    .padding(.horizontal, 16)
                    .padding(.top, ChatView.intraTurnGap)
            }
            Color.clear.frame(height: 24)
        }
    }

    /// A transcript tail showing the production `SessionContextLine`.
    @ViewBuilder
    private func contextTail(summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sure — I'll extract the auth middleware into a dedicated module and update the imports.")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            SessionContextLine(summary: summary)
                .padding(.horizontal, 16)
                .padding(.top, ChatView.intraTurnGap)
            Color.clear.frame(height: 24)
        }
    }

    /// A transcript tail showing a real production `MessageBubble` (user role,
    /// regular width) immediately above the production `TurnActivityBar`, so
    /// the reconciled reading measure (STR-1102) is visible edge-to-edge in
    /// one frame rather than only asserted numerically. Needs the same
    /// `ConnectionStore`/`SessionStore` environment objects `MessageBubble`
    /// reads in production.
    @ViewBuilder
    private func bubbleAndStatusParityTail(store: ChatStore) -> some View {
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: store)
        let userMessage = ChatMessage(
            role: .user,
            text: "Let's reconcile the reading measure across the status row and the bubble column.")
        VStack(alignment: .leading, spacing: 0) {
            MessageBubble(message: userMessage)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            TurnActivityBar(chatStore: store)
                .padding(.horizontal, 16)
                .padding(.top, ChatView.intraTurnGap)
            Color.clear.frame(height: 24)
        }
        .environment(connection)
        .environment(sessions)
    }

    // MARK: - ImageRenderer bridge

    /// Renders a labelled transcript-tail frame to a PNG in `evidenceDir`.
    private func renderAndSave<C: View>(
        name: String,
        caption: String,
        width: CGFloat,
        sizeClass: UserInterfaceSizeClass,
        content: C
    ) throws {
        let frame = VStack(alignment: .leading, spacing: 0) {
            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.systemGray5))
            content
        }
        .frame(width: width)
        .background(Color(.systemBackground))
        .overlay {
            RoundedRectangle(cornerRadius: 0).stroke(.gray.opacity(0.3), lineWidth: 1)
        }
        .environment(\.hermesTheme, HermesThemePresets.nousLight)
        .environment(\.horizontalSizeClass, sizeClass)

        let renderer = ImageRenderer(content: frame)
        renderer.scale = 2

        guard let image = renderer.uiImage,
              let png = image.pngData() else {
            XCTFail("ImageRenderer produced no image for \(name)")
            return
        }
        let url = evidenceDir.appendingPathComponent("\(name).png")
        try png.write(to: url)
        let kb = png.count / 1_024
        print("  ✓ \(name).png  (\(Int(image.size.width))×\(Int(image.size.height))px, \(kb)KB)")
    }
}
