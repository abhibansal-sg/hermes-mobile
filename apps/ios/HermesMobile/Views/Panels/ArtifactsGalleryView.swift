import SwiftUI
import Observation

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
/// selection re-fetches and resets the accumulated artifact list. Scrolling to
/// the bottom triggers load-more via ``ArtifactsGalleryModel/loadMore(type:api:)``
/// — a sentinel `onAppear` on the last grid item fires the next page.
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
    /// Observable model that owns all gallery state and fetch logic.
    @State private var model = ArtifactsGalleryModel()

    // MARK: - Body

    var body: some View {
        Group {
            if model.pluginUnavailable {
                unavailableView
            } else {
                contentView
            }
        }
        .navigationTitle("Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(type: filter.rawValue, api: control) }
        .onChange(of: filter) { Task { await model.load(type: filter.rawValue, api: control) } }
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

            switch model.phase {
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
                        Button("Try Again") {
                            Task { await model.load(type: filter.rawValue, api: control) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            case .loaded:
                if model.artifacts.isEmpty {
                    emptyState
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        artifactGrid(model.artifacts)
                        if model.isLoadingMore {
                            ProgressView()
                                .tint(theme.midground)
                                .padding(.vertical, 12)
                        }
                    }
                    .background(theme.bg)
                    .refreshable {
                        await model.load(type: filter.rawValue, api: control)
                    }
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
    private func artifactGrid(_ items: [Artifact]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 6) {
            ForEach(items) { artifact in
                ArtifactThumbnail(
                    artifact: artifact,
                    serverId: serverId,
                    profileId: profileId
                )
                .contentShape(Rectangle())
                .onTapGesture { openSourceSession(for: artifact) }
                .accessibilityLabel(artifact.displayName)
                .accessibilityAddTraits(.isButton)
                .onAppear {
                    // Sentinel: when the last item appears, load the next page.
                    if artifact.id == items.last?.id {
                        Task {
                            await model.loadMore(type: filter.rawValue, api: control)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 16)
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

// MARK: - ArtifactsGalleryModel

/// Observable model that owns all gallery state and fetch logic.
///
/// Separated from the view so tests can instantiate and drive it directly
/// without spinning a SwiftUI render tree. The view holds it as `@State`.
///
/// ## Pagination contract
///
/// - ``load(type:api:)`` always starts from `offset=0` (resets state). Call
///   it on initial appearance and after a filter change.
/// - ``loadMore(type:api:)`` fetches the next page using the stored
///   ``galleryOffset``. It is guarded by ``isLoadingMore``, ``hasMore``, and a
///   generation counter — stale pages arriving after a ``load()`` call are
///   discarded.
/// - ``hasMore`` is `true` when the accumulated count is less than the
///   server-reported ``galleryTotal``. Uses `total` (more precise than a
///   short-page heuristic).
@MainActor
@Observable
final class ArtifactsGalleryModel {

    // MARK: - Published state

    var phase: GalleryPhase = .loading
    var artifacts: [Artifact] = []
    /// Server-reported total matched count (before pagination).
    var galleryTotal: Int = 0
    /// Offset for the NEXT fetch (advanced by ``pageLimit`` after each page lands).
    var galleryOffset: Int = 0
    var isLoadingMore: Bool = false
    /// Set to `true` on a 404 response — plugin not deployed on this gateway.
    var pluginUnavailable: Bool = false

    // MARK: - Constants

    static let pageLimit: Int = 50

    // MARK: - Derived

    /// More pages exist when fewer results have landed than the server total.
    var hasMore: Bool { artifacts.count < galleryTotal }

    // MARK: - Seam (DEBUG only)

    /// Injectable fetch closure for unit tests. When set, bypasses the live
    /// ``RestClient`` call inside ``load(type:api:)`` and ``loadMore(type:api:)``.
    ///
    /// Signature: `(type: String, offset: Int) async throws -> ArtifactPage`
    ///
    /// The `api` parameter to `load`/`loadMore` is ignored when the seam is set,
    /// so tests do NOT need a real `RestClient`.
    #if DEBUG
    var fetchPage: ((String, Int) async throws -> ArtifactPage)?
    #endif

    // MARK: - Generation counter (stale-page guard)

    /// Incremented on each ``load()`` call. ``loadMore()`` snapshots the value
    /// before the async fetch and discards the result if the generation changed
    /// (i.e. the user changed the filter while the request was in flight).
    private(set) var generation: Int = 0

    // MARK: - Load (page 0, resets state)

    /// Fetch the first page for `type`. Resets all accumulated state.
    ///
    /// - Parameters:
    ///   - type: `ArtifactFilter.rawValue` (e.g. `"all"`, `"images"`).
    ///   - api: Live ``RestClient``; ignored when ``fetchPage`` seam is set.
    func load(type: String, api: RestClient) async {
        phase = .loading
        artifacts = []
        galleryTotal = 0
        galleryOffset = 0
        generation &+= 1

        do {
            let page = try await fetchOnePage(type: type, offset: 0, api: api)
            artifacts = assignIndices(page.results, startingAt: 0)
            galleryTotal = page.total
            galleryOffset = Self.pageLimit
            phase = .loaded
        } catch RestError.badStatus(404, _) {
            pluginUnavailable = true
        } catch {
            phase = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            )
        }
    }

    // MARK: - Load more (subsequent pages)

    /// Fetch the next page and append results (deduped by `messageId:urlOrPath`).
    ///
    /// No-ops when ``hasMore`` is false, ``isLoadingMore`` is true, or
    /// ``galleryOffset`` has already reached ``galleryTotal``. A generation
    /// counter discards pages that arrive after a ``load()`` call (filter change).
    ///
    /// ## Dedup key
    ///
    /// Cross-page dedup uses `"\(messageId):\(urlOrPath)"` (NOT `artifact.id`)
    /// because `artifact.id` is positional — a true cross-page duplicate has a
    /// different ``galleryIndex`` and therefore a different `id`.
    ///
    /// - Parameters:
    ///   - type: Current filter type string.
    ///   - api: Live ``RestClient``; ignored when ``fetchPage`` seam is set.
    func loadMore(type: String, api: RestClient) async {
        guard hasMore, !isLoadingMore,
              galleryOffset < galleryTotal else { return }

        let offset    = galleryOffset
        let gen       = generation
        let nextStart = artifacts.count   // base index for this page

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await fetchOnePage(type: type, offset: offset, api: api)
            // Discard if the user changed the filter while this was in flight.
            guard generation == gen else { return }

            // Dedup by messageId:urlOrPath — positional ids differ across pages
            // so we must use the content key, not artifact.id.
            let existing = Set(artifacts.map { "\($0.messageId):\($0.urlOrPath)" })
            let freshRaw = page.results.filter {
                !existing.contains("\($0.messageId):\($0.urlOrPath)")
            }
            // Assign stable gallery positions continuing from current count.
            let fresh = assignIndices(freshRaw, startingAt: nextStart)
            artifacts.append(contentsOf: fresh)

            // Advance by page limit (not appended count — message-level offset).
            galleryOffset = offset + Self.pageLimit
            // Update total in case the server's count changed between pages.
            galleryTotal = page.total
        } catch {
            // Load-more failure is silent — existing gallery remains readable.
            if Task.isCancelled { return }
        }
    }

    // MARK: - Internal

    /// Assigns sequential ``Artifact/galleryIndex`` values starting at `base`,
    /// returning new `Artifact` values with the index field set.
    private func assignIndices(_ items: [Artifact], startingAt base: Int) -> [Artifact] {
        items.enumerated().map { pair in
            var art = pair.element
            art.galleryIndex = base + pair.offset
            return art
        }
    }

    // MARK: - Internal

    /// Dispatches to the ``fetchPage`` seam (DEBUG) or the live endpoint.
    private func fetchOnePage(
        type: String, offset: Int, api: RestClient
    ) async throws -> ArtifactPage {
        #if DEBUG
        if let seam = fetchPage {
            return try await seam(type, offset)
        }
        #endif
        return try await api.artifacts(
            type: type, limit: Self.pageLimit, offset: offset
        )
    }
}

// MARK: - GalleryPhase

/// Load state for the gallery.
enum GalleryPhase: Sendable {
    case loading
    case loaded
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
    // Dynamic-Type-scaled icon/label sizes so tile text grows with Larger Text
    // (base values preserve the default-size layout).
    @ScaledMetric(relativeTo: .title) private var iconGlyphSize: CGFloat = 28
    @ScaledMetric(relativeTo: .caption2) private var tileNameFontSize: CGFloat = 10

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
                    .font(.system(size: iconGlyphSize))
                    .foregroundStyle(color)
                Text(artifact.displayName)
                    .font(.system(size: tileNameFontSize))
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var nameLabel: some View {
        Text(artifact.displayName)
            .font(.system(size: tileNameFontSize, weight: .medium))
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
