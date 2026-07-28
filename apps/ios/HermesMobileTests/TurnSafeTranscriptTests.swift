import XCTest
@testable import HermesMobile

/// Regression for the build-135 physical-device failure: the newest 50 raw
/// gateway rows began with an orphaned tool result, so the stateful transcript
/// normalizer synthesized a detached Work item and cached the malformed slice.
final class TurnSafeTranscriptTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TurnSafeTranscriptStub.requestedOffsets = []
    }

    func testBoundedFetchExpandsBackwardToUserBoundaryBeforeNormalizing() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "ios_fix_mid_turn_tail", withExtension: "json"
            )
        )
        let fixture = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtureURL)
        ) as? [String: Any]
        XCTAssertEqual(fixture?["first_row_role"] as? String, "tool")
        XCTAssertEqual(fixture?["orphan_tool_result_count"] as? Int, 1)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TurnSafeTranscriptStub.self]
        let rest = RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )

        let stored = try await fetchBoundedStockTranscript(
            rest: rest,
            sessionId: "tool-heavy-session",
            profile: nil,
            messageCount: 50,
            limit: 50
        )

        XCTAssertEqual(TurnSafeTranscriptStub.requestedOffsets, [10, 0])
        XCTAssertEqual(stored.first?.role, "user")
        XCTAssertEqual(stored.first?.wireId, 1)

        let declared = Set(
            stored.flatMap { ($0.toolCalls ?? []).map(\.callId) }
        )
        let orphaned = stored.filter {
            $0.role == "tool"
                && $0.toolCallId.map { !declared.contains($0) } == true
        }
        XCTAssertTrue(
            orphaned.isEmpty,
            "A renderable transcript window must not begin with an orphaned tool result"
        )

        let normalized = ChatStore.toChatMessages(stored)
        XCTAssertEqual(normalized.map(\.role), [.user, .assistant])
    }

    func testBoundedFetchUsesContinuationIdentityForCountAndOffset() async throws {
        CompressionContinuationStub.requestedMessagePaths = []
        CompressionContinuationStub.requestedOffsets = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompressionContinuationStub.self]
        let rest = RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )

        let stored = try await fetchBoundedStockTranscript(
            rest: rest,
            sessionId: "parent",
            profile: nil,
            messageCount: 333,
            limit: 50
        )

        XCTAssertEqual(
            CompressionContinuationStub.requestedMessagePaths,
            ["/api/sessions/parent/messages", "/api/sessions/child/messages"]
        )
        XCTAssertEqual(
            CompressionContinuationStub.requestedOffsets,
            [0, 131],
            "the tail offset must use the 181-row continuation, not the 333-row parent"
        )
        XCTAssertEqual(stored.first?.role, "user")
    }
}

private final class CompressionContinuationStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestedMessagePaths: [String] = []
    nonisolated(unsafe) static var requestedOffsets: [Int] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let components = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        let path = components?.path ?? ""
        if path == "/api/sessions/child" {
            sendJSON(["id": "child", "message_count": 181])
            return
        }
        if path == "/api/sessions/parent" {
            sendJSON(["id": "parent", "message_count": 333])
            return
        }

        let offset = (components?.queryItems ?? [])
            .first(where: { $0.name == "offset" })
            .flatMap { Int($0.value ?? "") } ?? 0
        Self.requestedMessagePaths.append(path)
        Self.requestedOffsets.append(offset)
        sendJSON([
            "session_id": "child",
            "messages": [[
                "id": offset + 1,
                "role": "user",
                "content": "tail",
                "timestamp": 1_700_000_000 + offset,
            ]],
            "pagination": [
                "limit": 50,
                "offset": offset,
                "returned": 1,
            ],
        ])
    }

    private func sendJSON(_ body: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TurnSafeTranscriptStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestedOffsets: [Int] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let components = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        if components?.path == "/api/sessions/tool-heavy-session" {
            sendJSON([
                "id": "tool-heavy-session",
                "message_count": 60,
            ])
            return
        }
        let items = components?.queryItems ?? []
        let offset = items.first(where: { $0.name == "offset" })
            .flatMap { Int($0.value ?? "") } ?? 0
        let limit = items.first(where: { $0.name == "limit" })
            .flatMap { Int($0.value ?? "") } ?? 50
        Self.requestedOffsets.append(offset)

        let rows = Self.rows.dropFirst(offset).prefix(limit)
        let body: [String: Any] = [
            "session_id": "tool-heavy-session",
            "messages": Array(rows),
            "pagination": [
                "limit": limit,
                "offset": offset,
                "returned": rows.count,
            ],
        ]
        sendJSON(body)
    }

    private func sendJSON(_ body: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static var rows: [[String: Any]] {
        var result: [[String: Any]] = [
            [
                "id": 1,
                "role": "user",
                "content": "Run the tool-heavy task",
                "timestamp": 1_700_000_001,
            ],
        ]
        for index in 0..<29 {
            let callID = "call-\(index)"
            result.append([
                "id": index * 2 + 2,
                "role": "assistant",
                "content": "",
                "timestamp": 1_700_000_002 + index * 2,
                "tool_calls": [[
                    "call_id": callID,
                    "function": [
                        "name": "terminal",
                        "arguments": #"{"command":"step"}"#,
                    ],
                ]],
                "finish_reason": "tool_calls",
            ])
            result.append([
                "id": index * 2 + 3,
                "role": "tool",
                "content": #"{"output":"done"}"#,
                "timestamp": 1_700_000_003 + index * 2,
                "tool_call_id": callID,
                "tool_name": "terminal",
            ])
        }
        result.append([
            "id": 60,
            "role": "assistant",
            "content": "Finished",
            "timestamp": 1_700_000_060,
            "finish_reason": "stop",
        ])
        return result
    }
}
