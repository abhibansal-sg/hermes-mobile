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
            }
        }
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
