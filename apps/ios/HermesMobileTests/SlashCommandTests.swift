import XCTest
@testable import HermesMobile

final class SlashCommandTests: XCTestCase {
    func testCatalogParseKeepsCategorizedAndUncategorizedCommands() throws {
        let raw: JSONValue = .object([
            "categories": .array([
                .object([
                    "name": .string("Session"),
                    "pairs": .array([
                        .array([.string("/usage"), .string("Show token usage")]),
                    ]),
                ]),
            ]),
            "pairs": .array([
                .array([.string("/usage"), .string("Show token usage")]),
                .array([.string("/memory"), .string("Review memory writes")]),
            ]),
            "skill_count": .number(1),
        ])

        let catalog = try XCTUnwrap(raw.decoded(as: SlashCommandCatalog.self))

        XCTAssertEqual(catalog.sections.map(\.name), ["Session", "More"])
        XCTAssertEqual(catalog.sections[0].commands.map(\.command), ["/usage"])
        XCTAssertEqual(catalog.sections[1].commands.map(\.command), ["/memory"])
        XCTAssertEqual(catalog.skillCount, 1)
    }

    func testCompletionDecoratesArgumentItemsWithParentCommandPrefix() throws {
        let raw: JSONValue = .object([
            "replace_from": .number(8),
            "items": .array([
                .object([
                    "text": .string("pending"),
                    "display": .string("pending"),
                    "meta": .string("Review pending writes"),
                    "group": .string("Options"),
                ]),
            ]),
        ])

        let response = try XCTUnwrap(raw.decoded(as: SlashCompletionResponse.self))
        let decorated = SlashCommandStore.decorateCompletionItems(
            response.completionItems,
            typedText: "/memory pen"
        )

        XCTAssertEqual(decorated.map(\.command), ["/memory pending"])
        XCTAssertEqual(decorated.first?.summary, "Review pending writes")
        XCTAssertEqual(decorated.first?.group, "Options")
    }

    func testSlashExecPayloadStripsLeadingSlash() async throws {
        let rpc = RecordingSlashRPC(responses: [
            "slash.exec": .object(["output": .string("ok")]),
        ])
        let service = SlashCommandService { method, params, _ in
            await rpc.request(method: method, params: params)
        }

        _ = try await service.execute(sessionId: "s1", command: "/usage")
        let call = await rpc.call(at: 0)

        XCTAssertEqual(call?.method, "slash.exec")
        XCTAssertEqual(call?.params["session_id"]?.stringValue, "s1")
        XCTAssertEqual(call?.params["command"]?.stringValue, "usage")
    }

    func testCommandDispatchPayloadCarriesNameAndArg() async throws {
        let rpc = RecordingSlashRPC(responses: [
            "command.dispatch": .object(["type": .string("exec"), "output": .string("pending")]),
        ])
        let service = SlashCommandService { method, params, _ in
            await rpc.request(method: method, params: params)
        }

        _ = try await service.dispatch(sessionId: "s1", name: "/memory", arg: "pending")
        let call = await rpc.call(at: 0)

        XCTAssertEqual(call?.method, "command.dispatch")
        XCTAssertEqual(call?.params["session_id"]?.stringValue, "s1")
        XCTAssertEqual(call?.params["name"]?.stringValue, "memory")
        XCTAssertEqual(call?.params["arg"]?.stringValue, "pending")
    }
}

private actor RecordingSlashRPC {
    struct Call: Sendable {
        let method: String
        let params: JSONValue
    }

    private let responses: [String: JSONValue]
    private var calls: [Call] = []

    init(responses: [String: JSONValue]) {
        self.responses = responses
    }

    func request(method: String, params: JSONValue) -> JSONValue {
        calls.append(Call(method: method, params: params))
        return responses[method] ?? .null
    }

    func call(at index: Int) -> Call? {
        calls.indices.contains(index) ? calls[index] : nil
    }
}
