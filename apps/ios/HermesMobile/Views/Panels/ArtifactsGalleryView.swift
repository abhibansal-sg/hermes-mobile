import SwiftUI

/// Cross-session artifacts gallery — images, files, and links collected from
/// all message transcripts, displayed in a ``LazyVGrid`` thumbnail grid.
///
/// Mounted from Settings (like ``UsageView`` / ``SkillsBrowserView``) via the
/// ``ControlPanel/artifacts`` case. Settings is presented as a sheet over the
/// main UI, so tapping an artifact must dismiss the sheet before the session
/// opens — otherwise `activeStoredId` is set while the sheet is still on screen
/// and the user stays stuck on the grid (M2 fix).
///
/// Calls `GET /api/plugins/hermes-mobile/artifacts?type=…` via
/// ``RestClient/artifacts(type:limit:offset:q:)``. On 404 (older gateway
/// without the plugin) it shows a `ContentUnavailableView` degradation note
/// rather than an error state. Only genuine 500 / transport failures surface as
/// errors.
///
/// Filter row: a segmented ``Picker`` with All / Images / Files / Links. Each
/// selection re-fetches. Results are flat (one artifact per grid cell),
/// matching the plugin's per-artifact response shape.
struct ArtifactsGalleryView: View {
    let control: RestClient
    /// Server URL string, forwarded to ``AttachmentBlobCache/Key`` scoping.
    let serverId: String
    /// Profile scope for the blob-cache key; blank → "all" (cache normalises).
    let profileId: String
    /// `nil` → panel opened without a live session store (unlikely in prod, but
    /// safe: tapping an artifact tile is a no-op when `nil`).
    let sessions: SessionStore?

    @Environment(\.hermesTheme) private var theme
    /// Dismisses the enclosing Settings sheet so tapping an artifact navigates
    /// the user out of Settings and into the session (M2).
    @Environment(\.dismiss) private var dismiss

    @State private var filter: ArtifactFilter = .all
    @State private var phase: GalleryPhase = .loading
    /// Set to `true` on a 404 response — plugin not deployed on this gateway.
    @State private var pluginUnavailable = false

    // MARK: - Body

    var body: some View {
        Group {
            if pluginUnavailable {
                unavailableView
            } else {
                contentView
            }
        }
        .navigationTitle("Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: filter) { Task { await load() } }
    }

    // MARK: - Content phases

    @ViewBuilder
    private var contentView: some View {
        // N2: filter picker lives OUTSIDE the phase switch so it stays visible
        // during .loading and .failed — prevents the picker from disappearing
        // while a re-fetch is in flight.
        VStack(spacing: 0) {
            filterPicker
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            switch phase {
            case .loading:
                ZStack {
                    theme.bg.ignoresSafeArea()
                    ProgressView("Loading artifacts\u{2026}")
                        .tint(theme.midground)
                }
                .frame(maxHeight: .infinity)
            case .failed(let msg):
                ZStack {
                    theme.bg.ignoresSafeArea()
                    ContentUnavailableView {
                        Label("Couldn't load artifacts", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(msg)
                            .accessibilityLabel(msg)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                }
                .frame(maxHeight: .infinity)
            case .loaded(let page):
                if page.results.isEmpty {
                    emptyState
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        artifactGrid(page.results)
                    }
                    .background(theme.bg)
                    .refreshable { await load() }
                }
            }
        }
        .background(theme.bg)
    }

    // MARK: - Filter picker

    private var filterPicker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(ArtifactFilter.allCases) { f in
                Text(f.label).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("artifactsFilterPicker")
    }

    // MARK: - Empty / unavailable states

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No \(filter.label)", systemImage: filter.systemImage)
        } description: {
            Text(filter == .all
                 ? "Messages with images, files, or links will appear here."
                 : "No \(filter.label.lowercased()) found in your sessions.")
        }
        .padding(.top, 24)
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("Artifacts need an updated gateway", systemImage: "arrow.down.circle")
        } description: {
            Text("Redeploy your hermes-agent to enable the artifacts gallery.")
        }
    }

    // MARK: - Grid

    private let gridColumns = [
        GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 6)
    ]

    @ViewBuilder
    private func artifactGrid(_ artifacts: [Artifact]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 6) {
            ForEach(artifacts) { artifact in
                ArtifactThumbnail(
                    artifact: artifact,
                    serverId: serverId,
                    profileId: profileId
                )
                .contentShape(Rectangle())
                .onTapGesture { openSourceSession(for: artifact) }
                .accessibilityLabel(artifact.displayName)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 16)
    }

    // MARK: - Load

    @MainActor
    private func load() async {
        phase = .loading
        do {
            let page = try await control.artifacts(type: filter.rawValue)
            phase = .loaded(page)
        } catch RestError.badStatus(404, _) {
            // Plugin endpoint absent on this gateway — degrade silently.
            pluginUnavailable = true
        } catch {
            phase = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            )
        }
    }

    // MARK: - Open source session

    /// Tap on a cell → dismiss the Settings sheet, then open the source session.
    ///
    /// The gallery is pushed inside the Settings sheet (``DrawerView`` presents
    /// ``SettingsView`` as a `.sheet`). Calling ``SessionStore/open(searchResult:)``
    /// sets `activeStoredId` while the sheet is still on screen — the user stays
    /// stuck on the grid. `dismiss()` first closes the whole sheet stack, then the
    /// session activates. Mirrors the `sessions.open` + `onNavigate()` pattern in
    /// ``DrawerView`` search results.
    ///
    /// Note: ``SessionStore/pendingSearchScroll`` is set by `open(searchResult:)`
    /// from the live `searchQuery` value, which is empty here → no message-level
    /// scroll. The tap opens the session; scrolling to a specific artifact is a
    /// future enhancement.
    private func openSourceSession(for artifact: Artifact) {
        guard let sessions else { return }
        let synth = SessionSearchResult(
            id: artifact.sessionId,
            snippet: artifact.urlOrPath,
            role: nil,
            source: nil,
            model: nil,
            sessionStarted: artifact.timestamp
        )
        sessions.open(searchResult: synth)
        // Dismiss the Settings sheet so the activated session becomes visible.
        dismiss()
    }
}

// MARK: - GalleryPhase

/// Load state for the gallery.
private enum GalleryPhase: Sendable {
    case loading
    case loaded(ArtifactPage)
    case failed(String)
}

// MARK: - ArtifactFilter

/// Segmented filter. `rawValue` matches the `type` query param values the
/// plugin endpoint accepts.
enum ArtifactFilter: String, CaseIterable, Identifiable, Sendable {
    case all, images, files, links
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:    return "All"
        case .images: return "Images"
        case .files:  return "Files"
        case .links:  return "Links"
        }
    }

    var systemImage: String {
        switch self {
        case .all:    return "square.grid.2x2"
        case .images: return "photo"
        case .files:  return "doc"
        case .links:  return "link"
        }
    }
}

// MARK: - ArtifactThumbnail

/// One cell in the artifact grid.
///
/// Images are served first from ``AttachmentBlobCache`` (blob previously fetched
/// for a chat message), then via `AsyncImage` for remote HTTP URLs, then as a
/// photo-placeholder icon for data URLs or local paths. Non-image kinds render
/// an icon tile.
private struct ArtifactThumbnail: View {
    let artifact: Artifact
    let serverId: String
    let profileId: String

    @Environment(\.hermesTheme) private var theme

    private let cellSize: CGFloat = 100

    var body: some View {
        ZStack(alignment: .bottom) {
            thumbnailContent
            if artifact.kind != "image" {
                nameLabel
            }
        }
        .frame(width: cellSize, height: cellSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.midground.opacity(0.15), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        switch artifact.kind {
        case "image":  imageThumbnail
        case "file":   iconTile(systemName: "doc.fill", color: theme.midground)
        case "link":   iconTile(systemName: "link.circle.fill", color: .blue)
        default:       iconTile(systemName: "paperclip", color: theme.mutedFg)
        }
    }

    @ViewBuilder
    private var imageThumbnail: some View {
        if let cached = cachedBlobImage() {
            // Previously-fetched blob — instantaneous, no network.
            Image(uiImage: cached)
                .resizable()
                .scaledToFill()
                .frame(width: cellSize, height: cellSize)
                .clipped()
        } else if let url = artifact.remoteURL {
            AsyncImage(url: url) { asyncPhase in
                switch asyncPhase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(width: cellSize, height: cellSize)
                        .clipped()
                case .failure:
                    iconTile(systemName: "photo.badge.exclamationmark", color: theme.mutedFg)
                default:
                    ZStack {
                        theme.card
                        ProgressView().tint(theme.mutedFg)
                    }
                }
            }
        } else {
            // data: URL or local path — show a photo placeholder icon.
            iconTile(systemName: "photo", color: theme.mutedFg)
        }
    }

    private func iconTile(systemName: String, color: Color) -> some View {
        ZStack {
            theme.card
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 28))
                    .foregroundStyle(color)
                Text(artifact.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var nameLabel: some View {
        Text(artifact.displayName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.45))
    }

    /// Look up a previously-cached image blob (e.g. loaded while reading a chat
    /// message). Returns `nil` when no cache key can be formed (no `size`, empty
    /// `serverId`) or when the image is not in memory.
    private func cachedBlobImage() -> UIImage? {
        guard let key = artifact.blobCacheKey(serverId: serverId, profileId: profileId)
        else { return nil }
        return AttachmentBlobCache.shared.image(for: key)
    }
}
