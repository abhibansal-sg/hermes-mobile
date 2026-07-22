import XCTest
@testable import HermesMobile

/// Stock v2026.7.20 JSON-RPC event frames must drive the production decoder
/// and transcript reducer without a relay-specific representation in between.
@MainActor
final class StockGatewayRenderConformanceTests: XCTestCase {
    private let runtimeID = "runtime-stock-render"

    private func event(_ json: String) throws -> GatewayEvent {
        let frame = try JSONDecoder().decode(
            JSONRPCInboundFrame.self,
            from: Data(json.utf8)
        )
        XCTAssertTrue(frame.isEvent)
        return try XCTUnwrap(GatewayEvent(
            params: frame.params ?? .null,
            broadcastGap: frame.broadcastGap
        ))
    }

    func testStockFramesRenderOneStandaloneAssistantBubble() throws {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = runtimeID
        sessions.activeStoredId = "stored-stock-render"
        chat.messages = [ChatMessage(role: .user, text: "Check the device")]

        let frames = [
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"runtime-stock-render","payload":{"role":"assistant"}}}"#,
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"reasoning.delta","session_id":"runtime-stock-render","payload":{"text":"Inspecting the connection."}}}"#,
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"runtime-stock-render","payload":{"tool_id":"tool-1","name":"terminal","args":{"command":"device-check"}}}}"#,
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.complete","session_id":"runtime-stock-render","payload":{"tool_id":"tool-1","name":"terminal","result":"connected","duration_s":0.2}}}"#,
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"runtime-stock-render","payload":{"text":"The device is connected.","status":"completed"}}}"#,
        ]

        for frame in frames { chat.handle(event: try event(frame)) }

        XCTAssertEqual(chat.messages.map(\.role), [.user, .assistant])
        let assistant = try XCTUnwrap(chat.messages.last)
        XCTAssertFalse(assistant.isStreaming)
        XCTAssertEqual(assistant.text, "The device is connected.")
        XCTAssertTrue(assistant.parts.contains { part in
            guard case .reasoning(_, let text) = part else { return false }
            return text == "Inspecting the connection."
        })
        XCTAssertTrue(assistant.parts.contains { part in
            guard case .tools(_, let tools, _, _) = part else { return false }
            return tools.count == 1 && tools[0].id == "tool-1"
        })
    }
}
