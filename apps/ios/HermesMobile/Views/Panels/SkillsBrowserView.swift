import SwiftUI

/// Skills browser: `GET /api/skills` grouped by category, searchable.
/// Each row has an enable/disable toggle that fires `PUT /api/skills/toggle`.
/// The "General" bucket always sorts to the bottom of the list.
struct SkillsBrowserView: View {
    let control: RestClient

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<[SkillEntry]> = .loading
    @State private var search = ""
    /// Optimistic enabled-state overrides: name → enabled.
    /// Cleared on next full reload.
    @State private var optimistic: [String: Bool] = [:]
    /// Names with an in-flight toggle request.
    @State private var toggling: Set<String> = []
    @State private var toggleError: String?

    init(control: RestClient) {
        self.control = control
    }

    var body: some View {
        PanelContent(phase: phase, label: "Loading skills\u{2026}", retry: { Task { await load() } }) { skills in
            let groups = grouped(filter(skills))
            List {
                ForEach(groups, id: \.category) { group in
                    Section {
                        ForEach(group.skills) { skill in
                            SkillRow(
                                skill: skill,
                                effectiveEnabled: optimistic[skill.name] ?? skill.enabled,
                                isToggling: toggling.contains(skill.name),
                                onToggle: { Task { await toggle(skill) } }
                            )
                            // PSF-05: apply themed card background per row so
                            // dark-palette skills lists don't render system-gray
                            // cells behind the skill name + toggle.
                            .listRowBackground(theme.card)
                        }
                    } header: {
                        Text(group.category)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(theme.mutedFg)
                            .textCase(nil)
                            .padding(.top, 8)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .searchable(text: $search, prompt: "Search skills")
            .overlay {
                if groups.isEmpty {
                    if skills.isEmpty {
                        ContentUnavailableView {
                            Label("No skills", systemImage: "wand.and.stars")
                        } description: {
                            Text("This gateway has no skills installed.")
                        }
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Toggle failed", isPresented: Binding(
            get: { toggleError != nil },
            set: { if !$0 { toggleError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(toggleError ?? "")
        }
        .task { await load() }
    }

    // MARK: Grouping / filtering

    private struct SkillGroup { let category: String; let skills: [SkillEntry] }

    private func filter(_ skills: [SkillEntry]) -> [SkillEntry] {
        guard !search.isEmpty else { return skills }
        let needle = search.lowercased()
        return skills.filter {
            $0.name.lowercased().contains(needle)
                || ($0.description?.lowercased().contains(needle) ?? false)
                || ($0.category?.lowercased().contains(needle) ?? false)
        }
    }

    private func grouped(_ skills: [SkillEntry]) -> [SkillGroup] {
        let buckets = Dictionary(grouping: skills) { $0.category?.isEmpty == false ? $0.category! : "General" }
        return buckets
            .map { SkillGroup(category: $0.key, skills: $0.value.sorted { $0.name < $1.name }) }
            .sorted { a, b in
                // "General" bucket always sorts last.
                if a.category == "General" { return false }
                if b.category == "General" { return true }
                return a.category < b.category
            }
    }

    // MARK: Actions

    private func load() async {
        if phase.value == nil { phase = .loading }
        optimistic.removeAll()
        do {
            phase = .loaded(try await control.skills())
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func toggle(_ skill: SkillEntry) async {
        guard !toggling.contains(skill.name) else { return }
        let current = optimistic[skill.name] ?? skill.enabled
        let next = !current
        // Optimistic update
        optimistic[skill.name] = next
        toggling.insert(skill.name)
        do {
            let confirmed = try await control.toggleSkill(name: skill.name, enabled: next)
            optimistic[skill.name] = confirmed
        } catch {
            // Revert on failure
            optimistic[skill.name] = current
            toggleError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        toggling.remove(skill.name)
    }
}

// MARK: - Row

private struct SkillRow: View {
    let skill: SkillEntry
    let effectiveEnabled: Bool
    let isToggling: Bool
    let onToggle: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Seal icon top-aligned to the title baseline.
            Image(systemName: effectiveEnabled ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(effectiveEnabled ? theme.midground : theme.mutedFg)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.fg)
                if let description = skill.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(2)
                }
                if !effectiveEnabled {
                    Text("Disabled")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.mutedFg)
                }
            }
            Spacer()
            // Per-row toggle
            ZStack {
                Toggle("", isOn: Binding(
                    get: { effectiveEnabled },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
                .disabled(isToggling)
                .accessibilityLabel("Toggle \(skill.name)")
                .accessibilityIdentifier("skillToggle_\(skill.name)")

                if isToggling {
                    ProgressView()
                        .controlSize(.small)
                        .padding(4)
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(isToggling ? 0.6 : 1)
    }
}
