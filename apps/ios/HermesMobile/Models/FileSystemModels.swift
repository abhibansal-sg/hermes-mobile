import Foundation

/// Decoded shapes for the patched gateway's two session-cwd file endpoints
/// (`GET /api/fs/list`, `GET /api/fs/read`) and for the `complete.path` RPC the
/// composer's @-file picker drives. Owned by Module F4A-A1 (composer / @-refs /
/// file browser). The wire contract is the pinned F4A interface — these models
/// match it field-for-field and are decoded with explicit `CodingKeys` (the
/// snake_case wire keys are mapped here, NOT via `convertFromSnakeCase`, so a
/// `RestClient.decode(strategy:)` choice can't double-transform them).

// MARK: - /api/fs/list

/// One entry returned by `GET /api/fs/list`. Directories sort before files;
/// `size` is bytes (0 for dirs), `modified` is epoch seconds.
struct FSEntry: Decodable, Equatable, Sendable, Identifiable {
    let name: String
    let isDir: Bool
    let size: Int
    /// Epoch seconds (float on the wire); optional so a server omission can't
    /// drop the whole entry.
    let modified: Double?

    /// Stable identity for `List`/`ForEach`: a directory listing has unique
    /// names, so the name is a sufficient id within one listing.
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case isDir = "is_dir"
        case size
        case modified
    }
}

/// The `GET /api/fs/list` `200` body: the absolute resolved `root`, the relative
/// `path` listed, the sorted `entries`, and a `truncated` flag set when the
/// directory exceeded the server's 1000-entry cap.
struct FSListResult: Decodable, Equatable, Sendable {
    let root: String
    let path: String
    let entries: [FSEntry]
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case root
        case path
        case entries
        case truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        entries = try c.decodeIfPresent([FSEntry].self, forKey: .entries) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    init(root: String, path: String, entries: [FSEntry], truncated: Bool) {
        self.root = root
        self.path = path
        self.entries = entries
        self.truncated = truncated
    }
}

// MARK: - /api/fs/read

/// How the gateway classified the bytes it read.
enum FSEncoding: String, Decodable, Sendable {
    /// The first up-to-cap bytes decoded as UTF-8 — `content` holds the text.
    case utf8 = "utf-8"
    /// The bytes did not decode as UTF-8 — `content` is null; show "Binary file".
    case binary
}

/// The `GET /api/fs/read` `200` body. `content` is the file text for `utf-8`
/// and `nil` for `binary`. `truncated` is true when a large-but-text file was
/// cut to the read cap (the server truncates rather than `413`-ing text).
/// `dataURL` carries an optional `data:<mime>;base64,…` string the patched
/// gateway can return for image files so the viewer can render them inline
/// (mirrors `LocalFilePreview` on the desktop which calls `readFileDataUrl`).
struct FSReadResult: Decodable, Equatable, Sendable {
    let path: String
    let size: Int
    let encoding: FSEncoding
    let content: String?
    let truncated: Bool
    /// `data:<mime>;base64,…` — present when the server chose to inline the
    /// file bytes as a data URL (image-optimised path). The viewer renders this
    /// as an inline `<Image>` rather than falling back to "Binary file".
    let dataURL: String?

    enum CodingKeys: String, CodingKey {
        case path
        case size
        case encoding
        case content
        case truncated
        case dataURL = "data_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        encoding = try c.decodeIfPresent(FSEncoding.self, forKey: .encoding) ?? .binary
        content = try c.decodeIfPresent(String.self, forKey: .content)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        dataURL = try c.decodeIfPresent(String.self, forKey: .dataURL)
    }

    init(
        path: String,
        size: Int,
        encoding: FSEncoding,
        content: String?,
        truncated: Bool,
        dataURL: String? = nil
    ) {
        self.path = path
        self.size = size
        self.encoding = encoding
        self.content = content
        self.truncated = truncated
        self.dataURL = dataURL
    }

    /// True for a binary file (content suppressed by the server).
    var isBinary: Bool { encoding == .binary }

    /// True when the path looks like an image the viewer should try to render
    /// inline (PNG, JPEG, GIF, HEIC, WebP, BMP, TIFF). The server MAY return a
    /// `data_url`; this flag tells the viewer to request/display the image path.
    var isImage: Bool { FSReadResult.imageExtensions.contains(pathExtension) }

    private var pathExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    /// Extensions treated as inline-renderable images (matches desktop
    /// `LocalFilePreview` image-kind detection and `FileRow` icon names).
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "tif"
    ]
}

// MARK: - Surfaced read errors

/// A read outcome the viewer renders specially (distinct from a transport
/// error): a `413` (over the 1 MB read cap) must show "Too large to preview"
/// rather than a generic network error.
enum FSReadError: Error, LocalizedError, Sendable {
    /// `413` — the file exceeds the server's hard read cap.
    case tooLarge(size: Int?)
    /// `403` — the requested path escaped the session root sandbox.
    case pathEscapesRoot
    /// `404` — the path is a directory or does not exist.
    case notAFile
    /// `404 {"error":"unknown session"}` — the session id no longer resolves to a
    /// live gateway session (server restarted / stale sid before the reconnect
    /// `session.resume` lands). R1-fix finding 2: the server no longer falls back
    /// to the dashboard cwd, so the browser surfaces this as "No Active Session"
    /// instead of a misleading "file not found".
    case noActiveSession
    /// Any other RestError surfaced verbatim.
    case other(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let size):
            if let size {
                let formatted = ByteCountFormatter.string(
                    fromByteCount: Int64(size),
                    countStyle: .file
                )
                return "Too large to preview (\(formatted))"
            }
            return "Too large to preview"
        case .pathEscapesRoot:
            return "That path is outside the working directory."
        case .notAFile:
            return "That file no longer exists."
        case .noActiveSession:
            return "No Active Session"
        case .other(let message):
            return message
        }
    }
}

// MARK: - complete.path (@-file references)

/// One autocomplete candidate from the `complete.path` RPC
/// (`{items:[{text, display, meta}]}`, capped at 30). `text` is the path the
/// composer inserts a token for; `display` is the human label; `meta` carries an
/// optional kind hint (e.g. "dir"/"file") the picker uses for its leading icon.
struct PathCompletionItem: Decodable, Equatable, Sendable, Identifiable {
    let text: String
    let display: String?
    let meta: String?

    /// `text` is unique within a single completion batch, so it doubles as id.
    var id: String { text }

    enum CodingKeys: String, CodingKey {
        case text
        case display
        case meta
    }

    /// The label to show in the picker row: `display` when the server provides
    /// one, otherwise the raw `text`.
    var label: String { (display?.isEmpty == false ? display : nil) ?? text }

    /// Whether this candidate names a directory, inferred from `meta`. Used only
    /// for the leading folder/doc icon — selection behavior is identical.
    var isDirectory: Bool {
        guard let meta = meta?.lowercased() else { return text.hasSuffix("/") }
        return meta.contains("dir") || meta.contains("folder") || text.hasSuffix("/")
    }
}
