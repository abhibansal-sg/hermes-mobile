import Foundation

/// One slash command row shown in the mobile composer launcher.
struct SlashCommandItem: Identifiable, Equatable, Sendable {
    let command: String
    let display: String
    let summary: String
    let group: String
    /// Optional completion-action marker from the gateway. Empty for normal rows.
    let action: String

    var id: String { "\(command)|\(display)|\(group)" }

    var insertionText: String {
        command.hasPrefix("/") ? command : "/\(command)"
    }
}

struct SlashCommandSection: Equatable, Sendable {
    let name: String
    let commands: [SlashCommandItem]
}

struct SlashCommandCatalog: Decodable, Equatable, Sendable {
    struct WireSection: Decodable, Equatable, Sendable {
        let name: String
        let pairs: [[String]]
    }

    let categories: [WireSection]?
    let pairs: [[String]]?
    let skillCount: Int?
    let warning: String?

    var sections: [SlashCommandSection] {
        var sections: [SlashCommandSection] = []
        var seen = Set<String>()

        for category in categories ?? [] {
            let commands = category.pairs.compactMap { pair -> SlashCommandItem? in
                guard let item = Self.item(from: pair, group: category.name) else { return nil }
                seen.insert(item.insertionText.lowercased())
                return item
            }
            if !commands.isEmpty {
                sections.append(SlashCommandSection(name: category.name, commands: commands))
            }
        }

        let uncategorized = (pairs ?? []).compactMap { pair -> SlashCommandItem? in
            guard let item = Self.item(from: pair, group: "Commands") else { return nil }
            return seen.contains(item.insertionText.lowercased()) ? nil : item
        }
        if !uncategorized.isEmpty {
            sections.append(SlashCommandSection(name: "More", commands: uncategorized))
        }

        return sections
    }

    var flatItems: [SlashCommandItem] {
        sections.flatMap(\.commands)
    }

    private static func item(from pair: [String], group: String) -> SlashCommandItem? {
        guard let raw = pair.first?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let summary = pair.count > 1 ? pair[1] : ""
        let command = raw.hasPrefix("/") ? raw : "/\(raw)"
        return SlashCommandItem(command: command, display: command, summary: summary, group: group, action: "")
    }
}

struct SlashCompletionResponse: Decodable, Equatable, Sendable {
    let items: [SlashCompletionWireItem]?
    let replaceFrom: Int?

    var completionItems: [SlashCommandItem] {
        let replace = replaceFrom ?? 1
        return (items ?? []).compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let command = text.hasPrefix("/") ? text : "/\(text)"
            return SlashCommandItem(
                command: command,
                display: item.display?.trimmedNonEmpty ?? command,
                summary: item.meta?.trimmedNonEmpty ?? "",
                group: item.group?.trimmedNonEmpty ?? (replace > 1 ? "Options" : "Commands"),
                action: item.action?.trimmedNonEmpty ?? ""
            )
        }
    }
}

struct SlashCompletionWireItem: Decodable, Equatable, Sendable {
    let text: String
    let display: String?
    let meta: String?
    let group: String?
    let action: String?
}

struct SlashCommandInvocation: Equatable, Sendable {
    let name: String
    let arg: String

    static func parse(_ raw: String) -> SlashCommandInvocation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.drop(while: { $0 == "/" })
        guard !body.isEmpty else { return nil }
        let parts = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return nil }
        let name = String(first).lowercased()
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return SlashCommandInvocation(name: name, arg: arg)
    }
}

struct SlashCommandDispatch: Equatable, Sendable {
    enum Kind: String, Sendable {
        case exec
        case plugin
        case alias
        case skill
        case send
        case prefill
    }

    let kind: Kind
    let output: String?
    let target: String?
    let name: String?
    let message: String?
    let notice: String?

    init?(json: JSONValue) {
        guard let type = json["type"]?.stringValue,
              let kind = Kind(rawValue: type) else { return nil }
        switch kind {
        case .exec, .plugin:
            self.kind = kind
            self.output = json["output"]?.stringValue
            self.target = nil
            self.name = nil
            self.message = nil
            self.notice = nil
        case .alias:
            guard let target = json["target"]?.stringValue else { return nil }
            self.kind = kind
            self.output = nil
            self.target = target
            self.name = nil
            self.message = nil
            self.notice = nil
        case .skill:
            guard let name = json["name"]?.stringValue else { return nil }
            self.kind = kind
            self.output = nil
            self.target = nil
            self.name = name
            self.message = json["message"]?.stringValue
            self.notice = nil
        case .send, .prefill:
            guard let message = json["message"]?.stringValue else { return nil }
            self.kind = kind
            self.output = nil
            self.target = nil
            self.name = nil
            self.message = message
            self.notice = json["notice"]?.stringValue
        }
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
