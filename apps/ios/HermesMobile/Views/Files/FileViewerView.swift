import SwiftUI
import UIKit

/// Native read-only text/image viewer for a single file fetched via
/// `GET /api/fs/read` (Module F4A-A1). Handles all content outcomes:
///
/// **Text** (`encoding == "utf-8"`, `content != nil`)
///   - Syntax-highlighted (language inferred from `path` extension via
///     `SyntaxHighlighter`/`RenderCache`) with a muted read-only line-number
///     gutter; selectable; long lines scroll horizontally without clipping the
///     gutter. Unknown/no extension → plain monospaced (never crashes).
///     `[Preview truncated]` appended + footer note when the server cut the
///     file at the 1 MB cap.
///
/// **Image** (path extension is a known image type)
///   - Requests the file with `&format=data_url`; renders the returned
///     `data_url` inline. Falls back to a loading / failed state if the server
///     does not support the param (no `data_url` in response → shows "Image
///     preview unavailable" with retry).
///
/// **Binary** (`encoding == "binary"`, `content == nil`, not an image)
///   - "Binary file (N bytes)" with nothing else offered.
///
/// **Too large** (`413`, over the 1 MB read cap)
///   - "Too large to preview (N MB)" with the formatted size.
///
/// **Mention seam** — a "Use in Message" button (toolbar + swipe action) calls
/// `onMentionFile(path)`. Default no-op; the integrator wires the closure so
/// a `@file:<path>` token is inserted in the composer WITHOUT touching
/// ChatView/ComposerView here.
///
/// **View modes** (STR-659/STR-701) — Source / Rendered (markdown-only) /
/// Diff (only when a non-empty unified diff is available), picked via the
/// leading toolbar menu when more than one applies. Auto-selection on load
/// matches the desktop client: Diff > Rendered > Source
/// (``FileViewerMode/autoSelect(diffText:isMarkdown:)``). The diff itself is
/// loaded best-effort through `GET /api/fs/diff`; clean files, non-repo
/// workspaces, and failed diff probes fall back to Rendered/Source without
/// blocking the normal file read.
///
/// FULL NATIVE (UI-I): `ScrollView` + `Text` / `Image`; identity via `theme`/`tint`.
struct FileViewerView: View {
    let rest: RestClient
    let sessionId: String
    /// Relative path under the session cwd.
    let path: String
    /// Called when the user taps "Use in Message". Receives the relative path
    /// so the caller can insert a `@file:<path>` token in the composer.
    /// Default no-op — wire this in the integrator/ChatView layer without
    /// editing this file.
    var onMentionFile: ((String) -> Void)?
    /// Scope identity for the on-disk image-blob cache (P4 cache-on-access).
    /// `serverId` = trimmed `ConnectionStore.serverURLString`; `profileId` =
    /// normalized `SessionStore.activeProfile`. Both default empty so existing
    /// call sites / previews compile and so a missing scope simply means the
    /// blob cache is bypassed — behaviour is byte-identical to today (network
    /// path intact). The cache is consulted/written only when BOTH are non-empty.
    var serverId: String = ""
    var profileId: String = ""

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<FSReadResult> = .loading
    @State private var imagePhase: ImagePhase = .idle
    @State private var didCopy = false
    @State private var mode: FileViewerMode = .source
    @State private var diffText: String?
    /// Once the user picks a mode explicitly, auto-selection (on load or when
    /// the diff fetch resolves) stops overriding their choice.
    @State private var userDidSelectMode = false

    // MARK: - Image state machine

    enum ImagePhase: Equatable {
        case idle
        case loading
        case loaded(UIImage)
        case failed(String)
    }

    var body: some View {
        PanelContent(phase: phase, retry: { Task { await load() } }) { result in
            content(result)
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .background(theme.bg)
        .task(id: path) { await load() }
    }

    private var fileName: String { (path as NSString).lastPathComponent }

    private var isMarkdownFile: Bool { FileViewerModeDetection.isMarkdown(path: path) }

    /// Modes the toolbar picker should offer for the CURRENT file — always
    /// includes Source; Rendered only for markdown; Diff only once a non-empty
    /// diff has resolved.
    private var availableModes: [FileViewerMode] {
        FileViewerMode.availableModes(diffText: diffText, isMarkdown: isMarkdownFile)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ result: FSReadResult) -> some View {
        if result.isImage {
            imageContent(result)
        } else if result.isBinary {
            ContentUnavailableView {
                Label("Binary file", systemImage: "doc.badge.gearshape")
            } description: {
                Text(binarySizeLabel(result.size))
            }
        } else if let text = result.content {
            modeContent(text, truncated: result.truncated)
        } else {
            // encoding utf-8 but no content — degrade gracefully.
            ContentUnavailableView("No content", systemImage: "doc")
        }
    }

    /// Routes text content to the active mode's renderer. `.rendered` and
    /// `.diff` are only ever active when ``availableModes`` actually offers
    /// them (markdown / non-empty diff respectively), so the `diffText ?? ""`
    /// fallback here is defensive, not a real code path.
    @ViewBuilder
    private func modeContent(_ text: String, truncated: Bool) -> some View {
        switch mode {
        case .source:
            textContent(text, truncated: truncated)
        case .rendered:
            ScrollView(.vertical) {
                FileMarkdownBodyView(text: text.isEmpty ? "(empty file)" : text)
                    .padding(16)
                    .accessibilityIdentifier("fileViewerRendered")
            }
            .background(theme.bg)
            .safeAreaInset(edge: .bottom) {
                if truncated {
                    truncationFooter
                }
            }
        case .diff:
            FileDiffView(diffText: diffText ?? "")
        }
    }

    // MARK: - Text view

    @ViewBuilder
    private func textContent(_ text: String, truncated: Bool) -> some View {
        // Vertical scroll wraps both the empty placeholder and the source grid
        // so the truncation footer applies uniformly. Horizontal scrolling is
        // delegated to the code column's own ScrollView so the line-number
        // gutter stays pinned as the left column (mirrors desktop SourceView).
        ScrollView(.vertical) {
            if text.isEmpty {
                Text("(empty file)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .accessibilityIdentifier("fileViewerText")
            } else {
                sourceTextGrid(text)
            }
        }
        .background(theme.bg)
        .safeAreaInset(edge: .bottom) {
            if truncated {
                truncationFooter
            }
        }
    }

    /// Highlighted source laid out as a read-only line-number gutter (left,
    /// pinned during horizontal scroll) beside the horizontally-scrollable,
    /// syntax-highlighted code column (right). Mirrors the desktop
    /// `preview-file.tsx` `SourceView` two-column grid without porting its
    /// virtualization / edit / diff / interactive line-selection.
    ///
    /// Both columns share `.system(.body, design: .monospaced)` so the gutter
    /// stays line-for-line aligned with the code (identical line metrics).
    @ViewBuilder
    private func sourceTextGrid(_ text: String) -> some View {
        let lineCount = Self.lineCount(for: text)
        HStack(alignment: .top, spacing: 12) {
            // Line-number gutter — read-only display only. Stays pinned as the
            // left column while the code column scrolls horizontally; scrolls
            // vertically in lockstep with the code (same font/line metrics).
            // Hidden from accessibility: the code Text (fileViewerText) is the
            // screen-reader surface; reading every number would be noise.
            Text(Self.lineNumberString(lineCount: lineCount))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.mutedFg)
                .frame(width: Self.gutterWidth(forLineCount: lineCount), alignment: .trailing)
                .accessibilityHidden(true)

            // Code column — horizontally scrollable so long lines pan, never clip.
            // The highlighter bakes `theme.fg` (and semantic colours) per-run into
            // the AttributedString, so no `.foregroundStyle` is needed here —
            // matches CodeBlockView's rendering of the same highlighter output.
            ScrollView(.horizontal, showsIndicators: true) {
                Text(highlightedSource(text))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 16)
                    .accessibilityIdentifier("fileViewerText")
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 16)
        .padding(.leading, 16)
    }

    /// Theme-aware, memoized highlighted source for `text`, using the language
    /// inferred from `path`. Unknown/no-extension files fall through to plain
    /// monospaced (the highlighter's baseColor-only output) — never crashes.
    private func highlightedSource(_ text: String) -> AttributedString {
        RenderCache.highlight(text, language: Self.highlightLanguage(forPath: path), baseColor: theme.fg)
    }

    // MARK: - Source helpers (pure / testable)

    /// Number of rendered lines for `text`: newline count + 1 (a trailing
    /// newline yields a final empty line, matching how `Text` renders it).
    /// Empty input is `0` so the gutter is skipped entirely for empty files.
    static func lineCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
    }

    /// The gutter string `"1\n2\n…\nN"` for `lineCount` lines. Right-aligned in
    /// the gutter frame so single- and multi-digit numbers share a right edge
    /// (matches the desktop SourceView right-aligned gutter).
    static func lineNumberString(lineCount: Int) -> String {
        guard lineCount > 0 else { return "" }
        return (1...lineCount).map(String.init).joined(separator: "\n")
    }

    /// Gutter width that fits the widest line number without clipping while
    /// staying modest on small screens: ~8pt per monospaced body digit + a
    /// trailing pad, clamped to [28, 80]. A 4-digit file (~9999 lines) ≈ 44pt.
    static func gutterWidth(forLineCount lineCount: Int) -> CGFloat {
        let digits = max(1, String(max(1, lineCount)).count)
        return min(max(CGFloat(digits) * 8 + 12, 28), 80)
    }

    /// Infer a `SyntaxHighlighter` language alias from the file `path`'s
    /// extension. Returns `nil` for no/unknown extensions so the highlighter
    /// renders plain monospaced text. Covers every alias the highlighter knows
    /// (swift, py/python, js/jsx/mjs/cjs, ts/tsx, sh/zsh/bash, json/jsonc/json5,
    /// yaml/yml, go/golang, rs/rust, sql, html/htm/xml, css/scss) via the
    /// extension (`.swift`, `.py`, `.ts`, `.sh`, `.json`, …).
    static func highlightLanguage(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, SyntaxHighlighter.isSupported(ext) else { return nil }
        return ext
    }

    private var truncationFooter: some View {
        Text("Preview truncated to 1 MB")
            .font(.caption2.weight(.medium))
            .foregroundStyle(theme.mutedFg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(theme.toolbarBg)
    }

    // MARK: - Image view

    @ViewBuilder
    private func imageContent(_ result: FSReadResult) -> some View {
        switch imagePhase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.bg)
                .task(id: path) { await loadImage(result: result) }
        case .loaded(let image):
            ScrollView([.vertical, .horizontal]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                    .accessibilityIdentifier("fileViewerImage")
                    .accessibilityLabel(fileName)
            }
            .background(theme.bg)
        case .failed(let message):
            ContentUnavailableView {
                Label("Image preview unavailable", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Mode picker (STR-701): only shown once there is an actual choice —
        // a plain non-markdown, clean file has nothing but Source to offer.
        if availableModes.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(availableModes) { candidate in
                        Button {
                            userDidSelectMode = true
                            mode = candidate
                        } label: {
                            Label(candidate.label, systemImage: candidate.systemImage)
                        }
                    }
                } label: {
                    Label(mode.label, systemImage: mode.systemImage)
                }
                .accessibilityIdentifier("fileViewerModePicker")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 4) {
                // "Use in Message" — the mention seam (audit finding). Default
                // no-op; the integrator wires onMentionFile to inject a
                // @file:<path> token in the composer.
                Button {
                    onMentionFile?(path)
                } label: {
                    Image(systemName: "at.badge.plus")
                        .accessibilityLabel("Use in message")
                }
                .accessibilityIdentifier("fileViewerUseInMessage")

                // Copy-contents button (only for text files with content).
                if case .loaded(let result) = phase,
                   let text = result.content,
                   !result.isBinary,
                   !result.isImage {
                    Button {
                        // Append sentinel when the preview was cut (audit finding).
                        let copied = result.truncated
                            ? text + "\n[Preview truncated]"
                            : text
                        UIPasteboard.general.string = copied
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            didCopy = false
                        }
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(didCopy ? "Copied" : "Copy file contents")
                }
            }
        }
    }

    // MARK: - Data

    private func binarySizeLabel(_ size: Int) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "Binary file (\(bytes)). No preview available."
    }

    private func load() async {
        if phase.value == nil { phase = .loading }
        imagePhase = .idle
        diffText = nil
        // Best-known mode BEFORE the diff resolves (no flicker to Source on
        // markdown files that turn out to have a diff too — auto-select just
        // upgrades to Diff a moment later if `refreshDiff` finds one).
        if !userDidSelectMode {
            mode = isMarkdownFile ? .rendered : .source
        }
        do {
            let result = try await rest.fsRead(sessionId: sessionId, path: path)
            phase = .loaded(result)
            // If this is an image file, kick off the image-data load immediately.
            if result.isImage {
                await loadImage(result: result)
            }
        } catch let error as FSReadError {
            phase = .failed(error.errorDescription ?? "Couldn't open file")
            return
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        await refreshDiff()
    }

    /// Best-effort diff fetch (STR-701). Fires AFTER `phase` is already loaded:
    /// the file content is on screen before this starts, so clean files,
    /// non-repo workspaces, stale sessions, or endpoint failures never block
    /// the normal file read.
    private func refreshDiff() async {
        do {
            let result = try await rest.fsDiff(sessionId: sessionId, path: path)
            diffText = result.hasChanges
                ? FileViewerModeDetection.normalizedDiffText(result.diff)
                : nil
        } catch {
            diffText = nil
        }
        if !userDidSelectMode {
            mode = FileViewerMode.autoSelect(diffText: diffText, isMarkdown: isMarkdownFile)
        }
    }

    /// Load image data: if the initial `fsRead` already returned a `data_url`
    /// (patched gateway fast-path), decode it directly. Otherwise, issue a
    /// second request with `&format=data_url` (the gateway-image path that
    /// mirrors the desktop's `readFileDataUrl`). If neither yields image data,
    /// set `.failed` with a user-facing message.
    private func loadImage(result: FSReadResult) async {
        imagePhase = .loading

        // P4 cache-on-access: serve from the on-disk image-blob cache if this
        // file was previously viewed/downloaded on this device for this
        // (server, profile). A hit short-circuits the network entirely; a miss
        // (or no scope) falls straight through to today's fetch path. The cache
        // is an accelerator, never a correctness dependency.
        let blobKey = blobCacheKey(result: result)
        if let key = blobKey, let cached = await AttachmentBlobCache.shared.image(for: key) {
            imagePhase = .loaded(cached)
            return
        }

        // Fast path: the initial fsRead already embedded a data URL.
        if let dataURL = result.dataURL, let decoded = await decodeDataURL(dataURL) {
            imagePhase = .loaded(decoded.image)
            await cacheBlob(decoded.data, key: blobKey)
            return
        }

        // Slow path: request the image bytes via the format=data_url param.
        do {
            let imageResult = try await rest.fsReadAsDataURL(sessionId: sessionId, path: path)
            if let dataURL = imageResult.dataURL, let decoded = await decodeDataURL(dataURL) {
                imagePhase = .loaded(decoded.image)
                // Prefer the freshest server-reported content identity.
                await cacheBlob(decoded.data, key: blobCacheKey(result: imageResult) ?? blobKey)
                return
            }
            // Server does not support the format param — show a clear failure.
            imagePhase = .failed("Image preview requires an updated gateway.")
        } catch let error as FSReadError {
            imagePhase = .failed(error.errorDescription ?? "Couldn't load image")
        } catch {
            imagePhase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The on-disk blob-cache key for THIS file, or `nil` when the scope is
    /// incomplete (serverId empty) — in which case the cache is bypassed and the
    /// network path runs exactly as today.
    private func blobCacheKey(result: FSReadResult) -> AttachmentBlobCache.Key? {
        let trimmedServer = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty,
              let version = result.contentVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else { return nil }
        return AttachmentBlobCache.Key(
            serverId: trimmedServer,
            profileId: profileId,
            sessionId: sessionId,
            path: path,
            contentVersion: version
        )
    }

    /// Persist freshly-decoded image bytes to the blob cache (cache-on-access).
    /// No-op when the key is nil. Fire-and-forget; never blocks the UI.
    private func cacheBlob(_ data: Data, key: AttachmentBlobCache.Key?) async {
        guard let key else { return }
        await AttachmentBlobCache.shared.store(data, for: key)
    }

    /// Decode a `data:<mime>;base64,<payload>` URL into a UIImage AND return the
    /// raw decoded bytes (so the bytes can be written to the blob cache without a
    /// re-encode). Returns `nil` when the URL is malformed or not a recognized
    /// image.
    private func decodeDataURL(_ dataURL: String) async -> (image: UIImage, data: Data)? {
        await AttachmentBlobCache.decodeDataURL(dataURL)
    }
}
