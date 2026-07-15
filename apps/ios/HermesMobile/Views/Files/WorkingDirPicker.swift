import SwiftUI

/// The new-session / change-cwd working-directory picker (Module F4A-A1, A1.3).
///
/// A thin wrapper over ``FileBrowserView`` in `.pickDirectory` mode that A2's
/// chat surface MOUNTS (iPhone sheet / iPad inspector) and supplies an `onPick`
/// closure to. Per the ownership boundary, A1 owns this self-contained view +
/// its `onPick` contract; A2 owns the `session.cwd.set` RPC call (handling
/// `4009`/`4016`/`4017`) and refreshing the file-browser root + composer @-file
/// cwd on success.
///
/// `onPick` receives the chosen directory's RELATIVE path under the current
/// session cwd (empty string = the cwd root). A2 resolves it to an ABSOLUTE cwd
/// for the RPC using the `root` the browser already knows — exposed here as a
/// convenience so A2 doesn't re-list: A2 calls `fsList` once for the root, joins
/// `root + "/" + relativePath`, and sends that as `cwd`. (A2 may instead pass the
/// relative path straight through if a future `session.cwd.set` accepts relative
/// — today it wants an absolute existing dir, hence the join.)
///
/// **No-active-session fallback** (audit finding): when `sessionId` is empty the
/// file browser cannot list anything. This wrapper detects that and shows a
/// self-contained error screen with a `Done` button so the user is not stuck
/// staring at a spinner.
///
/// **ABH-362**: The picker now shows the CURRENT cwd (truncated for display) at
/// the top, a one-line explainer so the user knows what picking a folder DOES,
/// and the current selection is visually highlighted. On change, the caller
/// posts a visible in-transcript system confirmation (handled in ChatView).
///
/// Gating: A2 only presents this when `capabilities.fs != .unavailable`.
struct WorkingDirPicker: View {
    /// REST client for `fsList` (built from the live connection).
    let rest: RestClient
    /// The active runtime session id (resolves the sandboxed cwd root).
    /// Pass an empty string / nil to trigger the no-active-session fallback.
    let sessionId: String
    /// Called with the chosen directory's RELATIVE path under the session cwd
    /// (empty = root). A2 forwards this to `session.cwd.set`.
    let onPick: (String) -> Void
    /// The CURRENT absolute cwd of the session (for display + highlight).
    /// Empty/nil = unknown (the explainer still shows; no highlight).
    var currentCwd: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if sessionId.isEmpty {
            // No-active-session fallback — its OWN NavigationStack + Done so
            // the user is never stuck (audit finding).
            NavigationStack {
                noSessionFallback
                    .navigationTitle("Choose Folder")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        } else {
            // The picker owns the ONE NavigationStack (R1 #6): FileBrowserView no
            // longer wraps its own, so drill-ins push within this stack and its
            // `dismiss()` pops the real sheet.
            NavigationStack {
                FileBrowserView(
                    rest: rest,
                    sessionId: sessionId,
                    mode: .pickDirectory,
                    onPick: onPick
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    explainerBanner
                }
            }
        }
    }

    // MARK: - ABH-362 Explainer banner

    /// A compact top banner that tells the user WHAT the picker does and shows
    /// the current cwd so the effect of picking is visible BEFORE you tap.
    /// Designed states: known cwd (folder icon + truncated path), unknown cwd
    /// (info icon + "not set yet"), and the one-line explainer always present.
    private var explainerBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: currentCwd.isEmpty ? "info.circle" : "folder")
                    .font(.caption)
                    .foregroundStyle(theme.midground)
                    .accessibilityHidden(true)
                if currentCwd.isEmpty {
                    Text("Pick a folder — Hermes will run commands from there.")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.mutedFg)
                } else {
                    Text("Current: \(WorkingDirectory.displayPath(currentCwd))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(theme.toolbarBg)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workingDirExplainer")
    }

    private var noSessionFallback: some View {
        ContentUnavailableView {
            Label("No Active Session", systemImage: "xmark.circle")
        } description: {
            Text("Connect to a session to browse and select a working directory.")
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(theme.midground)
        }
        .background(theme.bg)
    }
}

// MARK: - ABH-362 Display helpers (pure, unit-tested)

extension WorkingDirectory {

    /// Truncate an absolute path for compact display: collapse the home prefix
    /// to `~` and keep the last two path components so the leaf + parent are
    /// visible (e.g. `/Users/abc/proj/src` → `~/proj/src`; `/r/a/b/c` → `a/b/c`
    /// when no home prefix). Empty/nil → empty string.
    ///
    /// This is a PURE function (no IO, no globals except NSHomeDirectory which
    /// is deterministic per-process) so it is unit-tested without a live view.
    static func displayPath(_ absolutePath: String) -> String {
        let trimmed = absolutePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let home = NSHomeDirectory()
        var display = trimmed
        if !home.isEmpty, display.hasPrefix(home) {
            display = "~" + String(display.dropFirst(home.count))
        }
        return display
    }

    /// Build the in-transcript confirmation message for a successful cwd change.
    /// Pure + tested.
    static func confirmationMessage(absoluteCwd: String) -> String {
        "Working directory set to \(displayPath(absoluteCwd))"
    }

    // MARK: - ABH-362 E2E cwd-plumbing resolution (true-red regression target)

    /// The fully-resolved cwd round-trip from picker pick → `session.cwd.set`
    /// wire value → gateway adoption contract. This is the seam the
    /// ``WorkingDirectoryTests`` E2E suite exercises end-to-end WITHOUT a live
    /// gateway: it proves the picker's relative path, once joined to the
    /// file-browser root, is EXACTLY the absolute cwd sent to `session.cwd.set`
    /// (server.py:5718) and that the gateway's `_set_session_cwd`
    /// (server.py:1759 — `session["cwd"] = resolved` + `explicit_cwd = True`)
    /// adoption contract holds for it. Reverting this function to the old
    /// "send relativePath raw" bug makes the E2E tests FAIL (true-red).
    struct CwdPlumbingResult: Equatable {
        /// The absolute cwd the picker resolved and the RPC MUST send.
        let wireCwd: String
        /// The confirmation string posted to the transcript on success.
        let confirmation: String
    }

    /// Resolve the full picker → wire cwd → confirmation round-trip.
    ///
    /// - Parameters:
    ///   - root: The file-browser root (absolute), resolved by `fsList`.
    ///   - relativePath: The picker's RELATIVE pick under the root ("."/"./" = root).
    ///   - gatewayAdoptedCwd: The cwd the gateway reported back as adopted
    ///     (the `session.info` event's `cwd`, or the `session.cwd.set` result's
    ///     `cwd`). Pass `nil` only when the RPC failed (no adoption). Passing a
    ///     non-nil value triggers the E2E adoption assertion (see below).
    /// - Returns: The resolved wire cwd + confirmation, or `nil` if the adoption
    ///   check FAILED (gateway adopted a cwd that is NOT what we sent — a real
    ///   plumbing break the user would feel as "I picked it but it didn't take").
    ///
    /// **E2E adoption contract**: when `gatewayAdoptedCwd` is non-nil, the
    /// gateway's `_set_session_cwd` runs `resolved = realpath(expanduser(cwd))`,
    /// which on macOS normalizes a trailing slash and collapses redundant
    /// separators but does NOT change a clean absolute path. So for a clean
    /// input the adopted cwd MUST equal the wire cwd. A mismatch proves the
    /// picked path never reached the session cwd faithfully (the exact gap
    /// Abhi felt: "I pressed it and couldn't tell if it works"). The caller
    /// treats `nil` as a hard failure (surface the error, do NOT post a
    /// confirmation), so this guard is load-bearing for honest "it worked".
    static func resolveCwdPlumbing(
        root: String,
        relativePath: String,
        gatewayAdoptedCwd: String?
    ) -> CwdPlumbingResult? {
        let wire = absolutePath(root: root, relative: relativePath)
        guard let adopted = gatewayAdoptedCwd else {
            // RPC failed (busy / missing dir / transport) — return the resolved
            // values so the caller can still drive the RPC; the adoption check
            // is only meaningful on the success path.
            return CwdPlumbingResult(
                wireCwd: wire,
                confirmation: confirmationMessage(absoluteCwd: wire)
            )
        }
        // E2E adoption gate: the gateway must have adopted exactly the cwd we
        // sent. `_set_session_cwd` realpath-normalizes, which for a clean
        // absolute path is a no-op — so adopted == wire MUST hold. A drift
        // means the plumbing is broken (the picked path mutated in flight).
        guard adopted == wire else { return nil }
        return CwdPlumbingResult(
            wireCwd: wire,
            confirmation: confirmationMessage(absoluteCwd: wire)
        )
    }
}
