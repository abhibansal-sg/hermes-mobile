import Foundation
import Observation

@MainActor
@Observable
final class SlashCommandStore {
    private(set) var sections: [SlashCommandSection] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var catalog: SlashCommandCatalog?
    private var loadTask: Task<Void, Never>?

    var visibleItems: [SlashCommandItem] {
        sections.flatMap(\.commands)
    }

    func reset() {
        loadTask?.cancel()
        loadTask = nil
        sections = []
        isLoading = false
        errorMessage = nil
    }

    func update(input: String, client: HermesGatewayClient?) {
        guard let client else {
            reset()
            return
        }
        let slashText = Self.activeSlashText(in: input)
        guard let slashText else {
            reset()
            return
        }
        let service = SlashCommandService.live(client: client)
        update(input: slashText, service: service)
    }

    func update(input: String, service: SlashCommandService) {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let slashText = input
        loadTask = Task { [weak self] in
            do {
                let nextSections: [SlashCommandSection]
                if slashText == "/" {
                    let catalog = try await service.catalog()
                    nextSections = catalog.sections
                    await MainActor.run { self?.catalog = catalog }
                } else {
                    let response = try await service.completions(text: slashText)
                    let items = Self.decorateCompletionItems(response.completionItems, typedText: slashText)
                    nextSections = Self.sections(from: items, fallbackCatalog: await MainActor.run { self?.catalog })
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.sections = nextSections
                    self?.isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                let fallback = await MainActor.run { self?.localMatches(for: slashText) ?? [] }
                await MainActor.run {
                    self?.sections = fallback
                    self?.errorMessage = fallback.isEmpty ? ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) : nil
                    self?.isLoading = false
                }
            }
        }
    }

    nonisolated static func activeSlashText(in input: String) -> String? {
        guard input.hasPrefix("/") else { return nil }
        guard !input.contains(where: { $0.isNewline }) else { return nil }
        return input
    }

    nonisolated static func decorateCompletionItems(_ items: [SlashCommandItem], typedText: String) -> [SlashCommandItem] {
        let prefixMatch = typedText.range(of: #"^/\S+\s+"#, options: .regularExpression)
        guard let prefixMatch else { return items }
        let prefix = String(typedText[prefixMatch])
        return items.map { item in
            let raw = item.command.hasPrefix("/") ? String(item.command.dropFirst()) : item.command
            let command = raw.hasPrefix(prefix.dropFirst()) ? item.command : prefix + raw
            return SlashCommandItem(
                command: command,
                display: item.display,
                summary: item.summary,
                group: item.group.isEmpty ? "Options" : item.group,
                action: item.action
            )
        }
    }

    nonisolated private static func sections(from items: [SlashCommandItem], fallbackCatalog: SlashCommandCatalog?) -> [SlashCommandSection] {
        if !items.isEmpty {
            let grouped = Dictionary(grouping: items, by: \.group)
            let order = ["Commands", "Skills", "Options", "More"]
            let keys = grouped.keys.sorted { a, b in
                let ai = order.firstIndex(of: a) ?? Int.max
                let bi = order.firstIndex(of: b) ?? Int.max
                return ai == bi ? a < b : ai < bi
            }
            return keys.compactMap { key in
                guard let commands = grouped[key], !commands.isEmpty else { return nil }
                return SlashCommandSection(name: key, commands: commands)
            }
        }
        return fallbackCatalog?.sections ?? []
    }

    private func localMatches(for slashText: String) -> [SlashCommandSection] {
        guard let catalog else { return [] }
        let needle = slashText.lowercased()
        let matches = catalog.flatItems.filter { item in
            item.command.lowercased().hasPrefix(needle) || item.summary.lowercased().contains(needle.dropFirst())
        }
        return Self.sections(from: matches, fallbackCatalog: catalog)
    }
}
