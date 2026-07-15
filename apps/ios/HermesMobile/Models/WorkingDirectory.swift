import Foundation

/// Pure logic for the working-directory picker → `session.cwd.set` round-trip
/// (Module F4A-A2's wiring of A1's ``WorkingDirPicker``).
///
/// The picker returns a RELATIVE path under the session's sandboxed cwd root
/// (A1's `onPick` contract: empty string = the root itself). The gateway's
/// `session.cwd.set` RPC wants an ABSOLUTE existing directory (server.py:3249 /
/// `_set_session_cwd`), so A2 joins the relative path onto the `root` the file
/// browser already resolved. This enum holds that join (and its edge cases) plus
/// the `session.cwd.set` error-code mapping as PURE functions so both are unit-
/// tested without a live gateway.
enum WorkingDirectory {

    // MARK: - relative → absolute join

    /// Join the file-browser `root` (absolute cwd) with the picker's RELATIVE
    /// sub-path to form the absolute cwd to pass to `session.cwd.set`.
    ///
    /// Edge cases (all covered by unit tests):
    ///   - empty / "." relative → the root itself (picking "Use Working Directory
    ///     Root" returns ""), unchanged.
    ///   - nested relative ("a/b/c") → `root + "/" + relative`.
    ///   - a relative path with redundant separators or a trailing slash is
    ///     normalized (collapsed) so the gateway sees a clean absolute path.
    ///   - the root's own trailing slash is normalized away first so "root//sub"
    ///     never reaches the wire (the gateway resolves cwd by exact string).
    ///
    /// This deliberately does NOT resolve `..` — the file browser only ever drills
    /// DOWN (it joins child names onto the path, never "..") and the SERVER
    /// re-sandboxes anyway (realpath prefix guard on `/api/fs/list`; the cwd set
    /// itself only checks existence). The join's job is purely to reconstruct the
    /// absolute path the browser was already showing.
    static func absolutePath(root: String, relative: String) -> String {
        let trimmedRoot = stripTrailingSlashes(root)
        let rel = normalizedRelative(relative)
        guard !rel.isEmpty else { return trimmedRoot.isEmpty ? "/" : trimmedRoot }
        // Root "/" must not become "//sub".
        if trimmedRoot.isEmpty { return "/" + rel }
        return trimmedRoot + "/" + rel
    }

    /// Normalize a picker-returned relative path: trim whitespace, drop a leading
    /// "./" or bare ".", collapse repeated "/" and any trailing "/". Returns ""
    /// for the root sentinel (empty / "." / "./").
    static func normalizedRelative(_ relative: String) -> String {
        var value = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare "." or "./" is the root sentinel — same as empty.
        if value == "." || value == "./" { return "" }
        // Drop a single leading "./" so "./a/b" joins like "a/b".
        if value.hasPrefix("./") { value.removeFirst(2) }
        // Split on "/", dropping empty components (collapses "//" and trailing "/")
        // and any "." segments, then rejoin.
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        return parts.joined(separator: "/")
    }

    /// Strip any trailing slashes from an absolute root (but keep a lone "/" as
    /// the empty marker the join treats as root).
    private static func stripTrailingSlashes(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        // A lone "/" is the filesystem root; the join handles it as the empty case.
        return value == "/" ? "" : value
    }

    // MARK: - session.cwd.set error mapping

    /// A native, user-facing classification of a `session.cwd.set` failure. The
    /// gateway's pinned codes (server.py:3249): `4009` session busy, `4016` empty
    /// cwd, `4017` non-existent dir. Anything else is surfaced verbatim.
    enum SetError: Equatable, Sendable {
        /// `4009` — the session is mid-turn; cwd can't change while it runs.
        case sessionBusy
        /// `4016` — an empty cwd was sent (should not happen from the picker).
        case empty
        /// `4017` — the resolved directory does not exist on the server.
        case missingDirectory(String)
        /// Any other failure (transport, decode, unknown RPC code).
        case other(String)

        /// The native inline message shown to the user.
        var message: String {
            switch self {
            case .sessionBusy:
                return "Hermes is busy — finish or stop the current turn before changing the working directory."
            case .empty:
                return "Pick a folder to set as the working directory."
            case .missingDirectory(let detail):
                return detail.isEmpty ? "That working directory does not exist." : detail
            case .other(let detail):
                return detail.isEmpty ? "Couldn’t change the working directory." : detail
            }
        }
    }

    /// Map a thrown `session.cwd.set` error into the typed ``SetError`` the UI
    /// renders. `GatewayError.rpc(code:message:)` carries the gateway's pinned
    /// codes; every other error (transport / decode / cancel) folds to `.other`
    /// with its localized description.
    static func mapSetError(_ error: Error) -> SetError {
        if let gateway = error as? GatewayError, case let .rpc(code, message) = gateway {
            switch code {
            case GatewayErrorCode.sessionBusy:
                return .sessionBusy
            case GatewayErrorCode.cwdRequired:
                return .empty
            case GatewayErrorCode.cwdMissing:
                return .missingDirectory(message)
            default:
                return .other(message)
            }
        }
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .other(description)
    }
}
