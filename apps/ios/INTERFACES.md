# HermesMobile — Module Contract

Native SwiftUI client for the hermes gateway (JSON-RPC over WebSocket; see
`tui_gateway/server.py` and the reference TS client
`apps/shared/src/json-rpc-gateway.ts`).

## Hard rules (all modules)

- Swift 6, `SWIFT_STRICT_CONCURRENCY=complete`, min iOS 17.
- State management: `@Observable` (Observation framework), NOT ObservableObject.
- **No third-party dependencies.** Foundation/SwiftUI/Security/PhotosUI only.
- Wire/domain types in `HermesMobile/Models/` are FROZEN — read them, use them,
  do not redefine or duplicate them. If a model is missing something, extend in
  your own file via `extension`.
- Every file you create goes under the directory you own (listed below).
  XcodeGen globs pick up new files automatically; do not edit project.yml.
- All UI code `@MainActor`. Networking code must be actor-isolated or Sendable.

## Connection facts

- WS endpoint: `{base}/api/ws?token={token}` where base is `http(s)://host[:port]`.
  WS scheme follows base (http→ws, https→wss).
- **Host header override**: every HTTP request AND the WS upgrade `URLRequest`
  must set header `Host: 127.0.0.1` (the server validates Host against its
  loopback bind; Tailscale Serve preserves the public hostname otherwise).
- REST auth header: `X-Hermes-Session-Token: {token}`.
- First frame after WS connect is the `gateway.ready` event.
- Outbound request ids: `"r1"`, `"r2"`, … (string, monotonic).
- Dev override: if `ProcessInfo.processInfo.environment["HERMES_URL"]` and
  `["HERMES_TOKEN"]` are set (Xcode scheme / simctl launch env), the app
  auto-configures the connection with them, bypassing Keychain/UserDefaults.
- Attachments: `POST /api/upload` accepts png/jpg/jpeg/gif/webp/bmp/tiff only
  (25MB max, multipart field `file`). iOS photo picks MUST be converted to
  JPEG before upload (HEIC is rejected). Response `{path}` feeds `image.attach`.

## Module APIs

### Networking (owner: networking agent) — `HermesMobile/Networking/`

```swift
actor HermesGatewayClient {
    init()
    /// Single-consumer stream of server-push events. ConnectionStore is the
    /// only consumer and fans out to the stores.
    nonisolated var events: AsyncStream<GatewayEvent> { get }
    /// Single-consumer stream of connection state changes.
    nonisolated var stateChanges: AsyncStream<GatewayConnectionState> { get }
    var state: GatewayConnectionState { get }

    /// Opens the socket, waits for the HTTP 101 + first frame. Throws GatewayError.
    func connect(baseURL: URL, token: String) async throws
    func disconnect() async

    /// JSON-RPC call. Decodes `result` into T via JSONValue.decoded(as:).
    func request<T: Decodable & Sendable>(
        _ method: String,
        params: JSONValue,
        timeout: Duration
    ) async throws -> T
    /// Raw variant for callers that want the untyped result.
    func requestRaw(_ method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue
}
```

Behavior: receive loop parses `JSONRPCInboundFrame`; frames with id resolve the
pending continuation (error frame → `GatewayError.rpc`); `method=="event"`
frames yield `GatewayEvent(params:)` onto `events`. On socket failure: fail all
pending requests with `.notConnected`, emit `.closed/.failed` state, finish
neither stream (streams live for the client's lifetime; reconnect reuses them).
Default timeout 30s; use 120s for session.resume/session.create.

```swift
struct RestClient: Sendable {
    init(baseURL: URL, token: String)
    func status() async throws -> ServerStatus                       // GET /api/status
    func messages(sessionId: String) async throws -> [StoredMessage] // GET /api/sessions/{id}/messages
    func upload(data: Data, filename: String, mimeType: String) async throws -> UploadResult // POST /api/upload (multipart)
}

enum KeychainService {
    static func saveToken(_ token: String, server: String) throws
    static func loadToken(server: String) -> String?
    static func deleteToken(server: String)
}
```

### Stores (owner: stores agent) — `HermesMobile/Stores/`

```swift
@MainActor @Observable final class ConnectionStore {
    enum Phase: Equatable { case needsSetup, connecting, connected,
                            reconnecting(attempt: Int), offline(String?) }
    var phase: Phase
    var serverURLString: String          // persisted in UserDefaults "hermes.serverURL"
    let client: HermesGatewayClient
    var rest: RestClient? { get }

    init(sessionStore: SessionStore, chatStore: ChatStore)
    func bootstrap() async        // env override → saved config → needsSetup
    func configure(urlString: String, token: String) async -> String?  // nil on success, else error text
    func disconnect() async
    func handleScenePhase(_ scenePhase: ScenePhase)
}
```

ConnectionStore owns: the event-consumption task (routes GatewayEvents to
SessionStore/ChatStore), the reconnect loop (exponential backoff
`min(0.5 * 2^attempt, 30)s + jitter`, reset on success), and scene-phase
handling (on `.active`: probe, reconnect if dead, then `chatStore.backfill()`).

```swift
@MainActor @Observable final class SessionStore {
    var sessions: [SessionSummary]
    var activeRuntimeId: String?     // runtime session_id (this connection)
    var activeStoredId: String?      // stored_session_id (persistent)
    var isLoading: Bool

    func attach(connection: ConnectionStore, chat: ChatStore)  // called once by AppEnvironment
    func refresh() async                       // session.list
    func openNew() async throws                // session.create → activates
    func open(_ summary: SessionSummary) async throws // session.resume → activates + seeds ChatStore
    func delete(_ summary: SessionSummary) async
    func closeActive() async
}
```

```swift
@MainActor @Observable final class ChatStore {
    var messages: [ChatMessage]
    var isStreaming: Bool
    var pendingApproval: PendingApproval?
    var pendingClarification: PendingClarification?
    var lastError: String?

    func attach(connection: ConnectionStore, sessions: SessionStore)  // called once by AppEnvironment
    func handle(event: GatewayEvent)     // called by ConnectionStore's router
    func seed(from stored: [StoredMessage])  // on session open/backfill
    func send(text: String) async        // prompt.submit (+ attached image paths)
    func interrupt() async               // session.interrupt
    func respondApproval(approve: Bool, all: Bool) async
    func respondClarification(_ answer: String) async
    func backfill() async                // REST messages refetch after reconnect
}
```

ChatStore implements **delta coalescing**: `message.delta`/`thinking.delta`
text accumulates in a private buffer; a single scheduled task flushes to the
`messages` array at most every 40ms (one Observation mutation per frame, never
one per token). `message.complete` flushes immediately and finalizes
(status/usage/warning). Tool events update the streaming message's `tools`
timeline keyed by `tool_call_id`. Events whose `sessionId` does not match
`sessionStore.activeRuntimeId` are ignored (v1).

### Views (owners: views-shell agent, views-chat agent) — `HermesMobile/Views/`

Shell (views-shell agent): `RootView` (NavigationSplitView when
horizontalSizeClass == .regular, else NavigationStack), `ConnectionSetupView`
(URL + token fields, test+save via ConnectionStore.configure, error display),
`SessionListView` (rows: displayTitle, relative time, source badge,
message count; pull-to-refresh; swipe-to-delete; new-session toolbar button;
connection status pill).

Chat (views-chat agent): `ChatView` (scrolling transcript + composer +
approval/clarify banners), `MessageBubble` (markdown via
`AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace` fallback
to plain text), `ThinkingView` (collapsed-by-default DisclosureGroup),
`ToolActivityRow` (icon + name + summaryLine, expandable to argsSummary /
resultPreview), `ApprovalBanner` (title/description/target + Approve / Deny /
Approve All buttons), `ClarifyBanner` (question + choice chips + free-text),
`ComposerView` (TextField, send button, interrupt button while
`chatStore.isStreaming`, disabled logic), `SettingsSheet` (model name display,
interrupt-safe; full settings later).

### App glue (owner: parent) — `HermesMobile/App/`

`HermesMobileApp` + `AppEnvironment` wire the stores together and inject them
via `.environment(...)`. Already scaffolded; agents must not edit.

## Testing (owner: tests agent) — `HermesMobileTests/`

XCTest (not swift-testing). Cover: JSONValue round-trip + decoded(as:) snake_case,
JSONRPCInboundFrame shapes (response/error/event), GatewayEvent parsing of every
event type with realistic payloads from this doc, StoredMessage.text flattening
(string + block-array contents), backoff sequence math if exposed.
