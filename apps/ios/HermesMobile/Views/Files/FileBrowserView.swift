import SwiftUI

/// Native file browser over the patched gateway's `GET /api/fs/list` +
/// `GET /api/fs/read` (Module F4A-A1). Two modes share one drill-down `List`:
///
///   - **`.browse`** — tap a directory to drill in, tap a file to open the
///     native text viewer (``FileViewerView``). The default chat-surface file
///     browser (iPhone sheet / iPad inspector — MOUNTED by the chat surface,
///     not by this view).
///   - **`.pickDirectory`** — drill into directories and tap "Use This Folder"
///     to return the SELECTED directory's relative path to `onPick`, which the
///     chat surface forwards to `session.cwd.set` (the working-dir picker). Files
///     are shown disabled (they can't be a cwd).
///
/// FULL NATIVE (UI-I): `NavigationStack` + `List(.insetGrouped)` + system rows;
/// identity carried by `tint` / `theme`. No custom-drawn chrome.
///
/// Gating: the caller MUST only present this when `capabilities.fs !=
/// .unavailable`. The view itself degrades safely (an empty/`404` listing just
/// shows ``ContentUnavailableView``) but the affordance to reach it is gated
/// upstream so a stock server shows nothing.
struct FileBrowserView: View {

    /// What the browser is for.
    enum Mode: Equatable {
        /// Browse + open files (read-only viewer).
        case browse
        /// Select a directory and return its relative path (working-dir picker).
        case pickDirectory
    }

    /// REST client used for `fsList`/`fsRead` (built from the live connection).
    let rest: RestClient
    /// The active runtime session id — resolves the sandboxed cwd ROOT.
    let sessionId: String
    /// What this browser is for.
    var mode: Mode = .browse
    /// Called when the user confirms a directory in `.pickDirectory` mode. The
    /// argument is the directory's RELATIVE path under the session cwd (empty
    /// string = the cwd root itself). No-op in `.browse` mode.
    var onPick: ((String) -> Void)?
    /// Called when the user picks a file via "Use in Message" in `.browse` mode.
    /// Receives the file's relative path under the session cwd so the caller
    /// can insert a `@file:<path>` token in the composer. Default no-op — the
    /// integrator wires this closure; not touching ChatView/ComposerView here.
    var onMentionFile: ((String) -> Void)?
    /// Scope identity threaded to ``FileViewerView`` for the on-disk image-blob
    /// cache (P4 cache-on-access). `serverId` = trimmed
    /// `ConnectionStore.serverURLString`; `profileId` = normalized
    /// `SessionStore.activeProfile`. Both default empty so a caller that doesn't
    /// supply them simply bypasses the blob cache (network path unchanged).
    var serverId: String = ""
    var profileId: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme

    /// The relative sub-path currently listed ("" = cwd root). Drives the title
    /// and the `path` query param.
    @State private var path: String = ""
    @State private var phase: PanelPhase<FSListResult> = .loading
    /// Persisted dotfile-visibility toggle.
    @State private var showHidden = DefaultsKeys.fileBrowserShowHiddenValue()

    var body: some View {
        // No inner NavigationStack (R1 #6): the PRESENTER owns the stack
        // (WorkingDirPicker / the composer's Browse Files sheet wrap one at
        // the sheet root). Wrapping here made every drill-in — which pushes
        // another FileBrowserView — the root of its own fresh stack: browse
        // mode lost the back button, and pick-directory mode's `dismiss()`
        // popped the inner stack (a no-op) so the picker stayed stuck open
        // after picking any non-root folder.
        // PSF-09: labeled spinner so the loading state identifies what is being
        // fetched (matches the PanelContent label: convention used in CronJobsView).
        PanelContent(phase: phase, label: "Loading files\u{2026}", retry: { Task { await load() } }) { result in
            listing(result)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .background(theme.bg)
        .tint(theme.midground)
        .task(id: path) { await load() }
    }

    // MARK: - Title

    private var title: String {
        if path.isEmpty {
            return mode == .pickDirectory ? "Choose Folder" : "Files"
        }
        // Show the leaf directory name as the title for a drilled-in level.
        return (path as NSString).lastPathComponent
    }

    // MARK: - Listing

    @ViewBuilder
    private func listing(_ result: FSListResult) -> some View {
        let entries = visibleEntries(result.entries)
        List {
            if mode == .pickDirectory {
                Section {
                    Button {
                        onPick?(path)
                        dismiss()
                    } label: {
                        Label(
                            path.isEmpty ? "Use Working Directory Root" : "Use This Folder",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(theme.midground)
                    }
                    // PSF-06: row-level background — .listRowBackground on the
                    // Section was not reaching individual rows; the button row
                    // now gets the same card fill as every other row.
                    .listRowBackground(theme.card)
                    .accessibilityIdentifier("fileBrowserUseFolder")
                } footer: {
                    // Show the RELATIVE path (not absolute root) — more useful
                    // when you are deep in a sub-directory.
                    Text(path.isEmpty ? "/" : path)
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        .textSelection(.enabled)
                }
            }

            Section {
                ForEach(entries) { entry in
                    row(entry)
                        .listRowBackground(theme.card)
                }
            }
            // PSF-09: the section-header truncated banner is removed — the
            // safeAreaInset below the List already shows the truncated notice
            // in a compact top banner, so this duplicated it. One surface wins.
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        // Top safeAreaInset banner for truncated directories (audit finding).
        .safeAreaInset(edge: .top, spacing: 0) {
            if result.truncated {
                truncatedBanner
            }
        }
        .overlay {
            // PSF-11: improved empty-folder copy — distinguishes the "truly
            // empty" case from "hidden files are filtering everything out".
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("Empty folder", systemImage: "folder")
                } description: {
                    Text(showHidden
                         ? "This folder has no files."
                         : "No visible files. Tap the eye icon to show hidden files.")
                }
            }
        }
        .refreshable { await load() }
    }

    /// Compact top banner — shown via `safeAreaInset` so the list content
    /// slides down rather than being covered (audit finding: truncated-list
    /// banner via a top safeAreaInset).
    private var truncatedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(theme.midground)
                .accessibilityHidden(true)
            Text("Showing first 1 000 entries")
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.mutedFg)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(theme.toolbarBg)
    }

    @ViewBuilder
    private func row(_ entry: FSEntry) -> some View {
        if entry.isDir {
            NavigationLink {
                FileBrowserView(
                    rest: rest,
                    sessionId: sessionId,
                    mode: mode,
                    onPick: onPick,
                    onMentionFile: onMentionFile,
                    serverId: serverId,
                    profileId: profileId
                )
                .injectedPath(join(path, entry.name))
            } label: {
                FileRow(entry: entry, theme: theme)
            }
            .accessibilityIdentifier(rowIdentifier(entry))
        } else if mode == .browse {
            NavigationLink {
                FileViewerView(
                    rest: rest,
                    sessionId: sessionId,
                    path: join(path, entry.name),
                    onMentionFile: onMentionFile,
                    serverId: serverId,
                    profileId: profileId
                )
            } label: {
                FileRow(entry: entry, theme: theme)
            }
            .accessibilityIdentifier(rowIdentifier(entry))
        } else {
            // Directory-pick mode: files can't be a cwd. Render clearly
            // disabled — dimmed + non-interactive — so it reads as "not
            // selectable here" rather than an unresponsive tap (build-32 QA:
            // files looked tappable). `.allowsHitTesting(false)` makes the row
            // swallow no taps; the reduced opacity signals the disabled state.
            FileRow(entry: entry, theme: theme)
                .foregroundStyle(theme.mutedFg)
                .opacity(0.45)
                .allowsHitTesting(false)
                .accessibilityIdentifier(rowIdentifier(entry))
        }
    }

    /// A stable accessibility id per row so UI tests + the QA bridge can drive a
    /// specific entry. `fileRow.<name>` for a directory-listing entry; the confirm
    /// button keeps its own `fileBrowserUseFolder` id. Directories carry a `.dir`
    /// suffix so a drill-down target reads distinctly from a same-named file.
    private func rowIdentifier(_ entry: FSEntry) -> String {
        "fileRow.\(entry.name)" + (entry.isDir ? ".dir" : "")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Promote Show Hidden Files to a primary eye/eye.slash toolbar button
        // (audit finding: no longer buried in a menu).
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showHidden.toggle()
                UserDefaults.standard.set(showHidden, forKey: DefaultsKeys.fileBrowserShowHidden)
            } label: {
                Image(systemName: showHidden ? "eye.slash" : "eye")
                    .accessibilityLabel(showHidden ? "Hide hidden files" : "Show hidden files")
            }
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
    }

    // MARK: - Data

    /// Filter dotfiles per the persisted toggle; the server always returns them.
    private func visibleEntries(_ entries: [FSEntry]) -> [FSEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    private func load() async {
        if phase.value == nil { phase = .loading }
        do {
            let result = try await rest.fsList(sessionId: sessionId, path: path.isEmpty ? nil : path)
            phase = .loaded(result)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Join a relative parent path with a child name (no leading slash at root).
    private func join(_ parent: String, _ child: String) -> String {
        parent.isEmpty ? child : parent + "/" + child
    }

    private static func message(for error: Error) -> String {
        if let fsError = error as? FSReadError { return fsError.errorDescription ?? "Couldn't load" }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private extension FileBrowserView {
    /// Set the initial `path` for a drilled-in instance (NavigationLink
    /// destination). A separate helper so the `@State` seed is explicit.
    func injectedPath(_ path: String) -> FileBrowserView {
        var copy = self
        copy._path = State(initialValue: path)
        return copy
    }
}

// MARK: - Row

/// One directory-listing row: a leading folder/doc icon, the name, and a
/// relative-modified subtitle for files; directories show only the folder icon.
private struct FileRow: View {
    let entry: FSEntry
    let theme: HermesTheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDir ? "folder.fill" : iconName)
                .foregroundStyle(entry.isDir ? theme.midground : theme.mutedFg)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// For files: RELATIVE modified time only (e.g. "3 days ago"). Size is
    /// omitted from the subtitle to keep rows compact — the viewer shows size.
    /// Directories show nothing (their byte size is always 0).
    private var subtitle: String? {
        guard !entry.isDir else { return nil }
        guard let modified = entry.modified, modified > 0 else { return nil }
        let date = Date(timeIntervalSince1970: modified)
        return date.formatted(.relative(presentation: .named))
    }

    /// A coarse glyph by extension so common file kinds read at a glance.
    private var iconName: String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "tif":
            return "photo"
        case "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "rb", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "curlybraces"
        case "md", "txt", "rtf":
            return "doc.text"
        case "zip", "tar", "gz", "tgz", "bz2":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }
}
