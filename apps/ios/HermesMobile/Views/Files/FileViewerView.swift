import SwiftUI
import UIKit

/// Native read-only text/image viewer for a single file fetched via
/// `GET /api/fs/read` (Module F4A-A1). Handles all content outcomes:
///
/// **Text** (`encoding == "utf-8"`, `content != nil`)
///   - Mono font, selectable; `[Preview truncated]` appended + footer note when
///     the server cut the file at the 1 MB cap.
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
        .task { await load() }
    }

    private var fileName: String { (path as NSString).lastPathComponent }

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
            textContent(text, truncated: result.truncated)
        } else {
            // encoding utf-8 but no content — degrade gracefully.
            ContentUnavailableView("No content", systemImage: "doc")
        }
    }

    // MARK: - Text view

    @ViewBuilder
    private func textContent(_ text: String, truncated: Bool) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "(empty file)" : text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.fg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .accessibilityIdentifier("fileViewerText")
        }
        .background(theme.bg)
        .safeAreaInset(edge: .bottom) {
            if truncated {
                truncationFooter
            }
        }
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
        do {
            let result = try await rest.fsRead(sessionId: sessionId, path: path)
            phase = .loaded(result)
            // If this is an image file, kick off the image-data load immediately.
            if result.isImage {
                await loadImage(result: result)
            }
        } catch let error as FSReadError {
            phase = .failed(error.errorDescription ?? "Couldn't open file")
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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
        let blobKey = blobCacheKey(size: result.size)
        if let key = blobKey, let cached = AttachmentBlobCache.shared.image(for: key) {
            imagePhase = .loaded(cached)
            return
        }

        // Fast path: the initial fsRead already embedded a data URL.
        if let dataURL = result.dataURL, let decoded = decodeDataURL(dataURL) {
            imagePhase = .loaded(decoded.image)
            cacheBlob(decoded.data, key: blobKey)
            return
        }

        // Slow path: request the image bytes via the format=data_url param.
        do {
            let imageResult = try await rest.fsReadAsDataURL(sessionId: sessionId, path: path)
            if let dataURL = imageResult.dataURL, let decoded = decodeDataURL(dataURL) {
                imagePhase = .loaded(decoded.image)
                // Prefer the freshest server-reported size for the cache key.
                cacheBlob(decoded.data, key: blobCacheKey(size: imageResult.size) ?? blobKey)
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
    private func blobCacheKey(size: Int) -> AttachmentBlobCache.Key? {
        let trimmedServer = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else { return nil }
        return AttachmentBlobCache.Key(
            serverId: trimmedServer,
            profileId: profileId,
            sessionId: sessionId,
            path: path,
            size: size
        )
    }

    /// Persist freshly-decoded image bytes to the blob cache (cache-on-access).
    /// No-op when the key is nil. Fire-and-forget; never blocks the UI.
    private func cacheBlob(_ data: Data, key: AttachmentBlobCache.Key?) {
        guard let key else { return }
        AttachmentBlobCache.shared.store(data, for: key)
    }

    /// Decode a `data:<mime>;base64,<payload>` URL into a UIImage AND return the
    /// raw decoded bytes (so the bytes can be written to the blob cache without a
    /// re-encode). Returns `nil` when the URL is malformed or not a recognized
    /// image.
    private func decodeDataURL(_ dataURL: String) -> (image: UIImage, data: Data)? {
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.startIndex..<commaIndex]
        guard header.contains(";base64") else { return nil }
        let payload = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        return (image, data)
    }
}
