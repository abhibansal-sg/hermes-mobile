import Foundation

struct SlashCommandService: Sendable {
    typealias RequestRaw = @Sendable (_ method: String, _ params: JSONValue, _ timeout: Duration) async throws -> JSONValue

    private let requestRaw: RequestRaw

    init(requestRaw: @escaping RequestRaw) {
        self.requestRaw = requestRaw
    }

    static func live(client: HermesGatewayClient) -> SlashCommandService {
        SlashCommandService { method, params, timeout in
            try await client.requestRaw(method, params: params, timeout: timeout)
        }
    }

    func catalog() async throws -> SlashCommandCatalog {
        let raw = try await requestRaw("commands.catalog", .object([:]), .seconds(30))
        guard let catalog = raw.decoded(as: SlashCommandCatalog.self) else {
            throw GatewayError.decoding(method: "commands.catalog", underlying: "result did not match SlashCommandCatalog")
        }
        return catalog
    }

    func completions(text: String) async throws -> SlashCompletionResponse {
        let raw = try await requestRaw(
            "complete.slash",
            .object(["text": .string(text)]),
            .seconds(30)
        )
        guard let response = raw.decoded(as: SlashCompletionResponse.self) else {
            throw GatewayError.decoding(method: "complete.slash", underlying: "result did not match SlashCompletionResponse")
        }
        return response
    }

    func execute(sessionId: String, command: String) async throws -> JSONValue {
        try await requestRaw(
            "slash.exec",
            .object([
                "session_id": .string(sessionId),
                "command": .string(command.strippingLeadingSlashes()),
            ]),
            .seconds(180)
        )
    }

    func dispatch(sessionId: String, name: String, arg: String) async throws -> JSONValue {
        try await requestRaw(
            "command.dispatch",
            .object([
                "session_id": .string(sessionId),
                "name": .string(name.strippingLeadingSlashes()),
                "arg": .string(arg),
            ]),
            .seconds(180)
        )
    }
}

extension HermesGatewayClient {
    func commandsCatalog() async throws -> SlashCommandCatalog {
        try await SlashCommandService.live(client: self).catalog()
    }

    func completeSlash(text: String) async throws -> SlashCompletionResponse {
        try await SlashCommandService.live(client: self).completions(text: text)
    }

    func executeSlash(sessionId: String, command: String) async throws -> JSONValue {
        try await SlashCommandService.live(client: self).execute(sessionId: sessionId, command: command)
    }

    func dispatchCommand(sessionId: String, name: String, arg: String) async throws -> JSONValue {
        try await SlashCommandService.live(client: self).dispatch(sessionId: sessionId, name: name, arg: arg)
    }
}

private extension String {
    func strippingLeadingSlashes() -> String {
        String(drop(while: { $0 == "/" }))
    }
}
