import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
/// **Mention seam** — when the integrator supplies `onMentionFile`, a "Use in
/// Message" button inserts a `@file:<path>` token in the composer without
/// coupling this viewer to ChatView/ComposerView.
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

    // MARK: - Export state (W25 files-phase-1: Share + Save to Files)

    /// True while file bytes are being fetched/prepared for a Share/Save action.
    @State private var isPreparingExport = false
    /// Surfaced when the file can't be fetched/prepared for export.
    @State private var exportError: String?
    /// Temp-file URL wrapper driving the Share sheet (`nil` = not presented).
    @State private var shareURL: IdentifiableFileURL?
    /// Document + presentation flag driving the "Save to Files" `.fileExporter`.
    @State private var exportDocument: DataFileDocument?
    @State private var showExporter = false

    /// Which export affordance the user tapped.
    private enum ExportAction { case share, save }

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
        .sheet(item: $shareURL) { payload in
            FileShareSheet(url: payload.url)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: fileName
        ) { _ in
            // Success or user-cancel both just dismiss; a real write error is
            // rare (user picks the destination) and surfaced by the system UI.
            exportDocument = nil
        }
        .alert("Couldn't Export", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
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
            // No inline preview, but no longer a dead end (audit finding): surface
            // size + type and offer Share / Save to Files, fetching the bytes via
            // the `format=data_url` read path on demand.
            ContentUnavailableView {
                Label("Binary file", systemImage: "doc.badge.gearshape")
            } description: {
                Text(binarySizeLabel(result.size))
            } actions: {
                Button {
                    startExport(.share)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("fileViewerBinaryShare")
                Button {
                    startExport(.save)
                } label: {
                    Label("Save to Files", systemImage: "arrow.down.doc")
                }
                .accessibilityIdentifier("fileViewerBinarySave")
            }
            .disabled(isPreparingExport)
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
                // Share / Save to Files (audit finding: the viewer was read-only).
                // Available once the file has loaded, for text, image, AND binary —
                // bytes are fetched on demand via the REST read path.
                if phase.value != nil {
                    Menu {
                        Button {
                            startExport(.share)
                        } label: {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            startExport(.save)
                        } label: {
                            Label("Save to Files", systemImage: "arrow.down.doc")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityLabel("Share or save file")
                    }
                    .disabled(isPreparingExport)
                    .accessibilityIdentifier("fileViewerExportMenu")
                }

                if let onMentionFile {
                    Button {
                        onMentionFile(path)
                    } label: {
                        Image(systemName: "at.badge.plus")
                            .accessibilityLabel("Use in message")
                    }
                    .accessibilityIdentifier("fileViewerUseInMessage")
                }

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

    // MARK: - Export (Share + Save to Files)

    /// The UTType used to label an exported/saved file — resolved from the
    /// server-reported MIME first, then the path extension, defaulting to `.data`.
    private var exportContentType: UTType {
        if let mime = phase.value?.mimeType,
           !mime.isEmpty,
           let type = UTType(mimeType: mime) {
            return type
        }
        let ext = (path as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }

    /// Kick off a Share or Save action: fetch the bytes off the main run loop's
    /// critical path, then present the corresponding UI. Re-entrancy guarded.
    private func startExport(_ action: ExportAction) {
        guard !isPreparingExport else { return }
        Task { await prepareExport(action) }
    }

    @MainActor
    private func prepareExport(_ action: ExportAction) async {
        isPreparingExport = true
        defer { isPreparingExport = false }

        guard let bytes = await exportBytes() else {
            exportError = "Couldn't load this file to \(action == .share ? "share" : "save"). "
                + "It may be too large to fetch or no longer available."
            return
        }
        switch action {
        case .share:
            do {
                let name = fileName
                let url = try await Task.detached {
                    try Self.writeTempFile(bytes, fileName: name)
                }.value
                shareURL = IdentifiableFileURL(url: url)
            } catch {
                exportError = "Couldn't prepare the file: \(error.localizedDescription)"
            }
        case .save:
            exportDocument = DataFileDocument(data: bytes, contentType: exportContentType)
            showExporter = true
        }
    }

    /// Resolve the raw bytes for the current file:
    /// * text → UTF-8 of the shown content (with the truncation sentinel);
    /// * image / binary → the original bytes via the `format=data_url` read path
    ///   (falling back to a re-encoded PNG for an already-decoded image).
    private func exportBytes() async -> Data? {
        guard let result = phase.value else { return nil }

        if let text = result.content, !result.isBinary, !result.isImage {
            let full = result.truncated ? text + "\n[Preview truncated]" : text
            return full.data(using: .utf8)
        }

        // Prefer the original bytes: an inline data URL from the initial read, or a
        // fresh `format=data_url` fetch (images already have this; binaries get it
        // from the W25 gateway change).
        if let dataURL = result.dataURL {
            if let data = await Task.detached(operation: {
                Self.decodeDataURLToData(dataURL)
            }).value { return data }
        }
        if let fetched = try? await rest.fsReadAsDataURL(sessionId: sessionId, path: path),
           let dataURL = fetched.dataURL {
            if let data = await Task.detached(operation: {
                Self.decodeDataURLToData(dataURL)
            }).value { return data }
        }

        // Last resort for an image the viewer already decoded but whose original
        // bytes we couldn't re-fetch: re-encode the on-screen bitmap as PNG.
        if result.isImage, case .loaded(let image) = imagePhase {
            return await Task.detached { image.pngData() }.value
        }
        return nil
    }

    /// Decode a `data:<mime>;base64,<payload>` URL (or a non-base64 `data:` URL)
    /// to its raw bytes. Unlike ``decodeDataURL`` this does not require the bytes
    /// to be a decodable image, so it works for arbitrary binary files.
    nonisolated static func decodeDataURLToData(_ dataURL: String) -> Data? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let meta = dataURL[dataURL.startIndex..<commaIndex]
        let payload = String(dataURL[dataURL.index(after: commaIndex)...])
        guard meta.hasPrefix("data:") else { return nil }
        if meta.contains(";base64") {
            let cleaned = payload.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            return Data(base64Encoded: cleaned)
        }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    /// Write export bytes to a uniquely-named temp file so the Share sheet can
    /// present it with the real filename (and downstream apps get a proper name).
    nonisolated private static func writeTempFile(_ data: Data, fileName: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-share", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName.isEmpty ? "file" : fileName)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Export support types

/// Identifiable wrapper so a prepared temp-file URL can drive `.sheet(item:)`.
private struct IdentifiableFileURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// Minimal `UIActivityViewController` bridge for the Share sheet.
private struct FileShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Byte-backed `FileDocument` for the "Save to Files" `.fileExporter`. Export-only
/// (the reader init is required by the protocol but the viewer never imports).
struct DataFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data
    var contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = .data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
