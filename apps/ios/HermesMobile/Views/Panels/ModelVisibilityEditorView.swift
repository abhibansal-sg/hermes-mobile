import SwiftUI

// MARK: - Edit Models (ABH-84 follow-up)
//
// iOS port of the desktop's "Edit models" dialog
// (`components/model-visibility-dialog.tsx`): curate WHICH models show in the
// session model picker. One row per model FAMILY (a base model and its
// `…-fast` sibling share a single toggle), grouped by provider, searchable.
//
// Semantics (shared with desktop via `ModelVisibility`):
//   * nil stored set  ⇒ curated default (top-N families per provider).
//   * Any toggle materializes the effective set, then mutates it.
//   * "Reset" clears the customization back to the curated default.
//
// Persistence is client-local (UserDefaults) — a display preference, not
// gateway state.

struct ModelVisibilityEditorView: View {
    let options: ModelOptions
    @Binding var visibleKeys: Set<String>?

    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose which models appear in the model picker. The chat's current model always shows.")
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                        .listRowBackground(theme.card)
                }

                ForEach(providersWithModels) { provider in
                    let families = matchingFamilies(provider)
                    if !families.isEmpty {
                        Section(provider.name) {
                            ForEach(families) { family in
                                familyToggleRow(provider: provider, family: family)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .searchable(text: $search, prompt: "Search models")
            .overlay {
                if noResults {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationTitle("Edit Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        visibleKeys = nil
                        ModelVisibility.save(nil)
                    }
                    .disabled(visibleKeys == nil)
                    .accessibilityHint("Restore the default model list")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func familyToggleRow(provider: ModelProvider, family: ModelFamily) -> some View {
        let key = ModelVisibility.key(provider: provider.slug, model: family.id)
        Toggle(isOn: bindingFor(key: key)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(family.id)
                    .font(.body)
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if family.fastId != nil {
                    Text("Includes fast variant")
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                }
            }
        }
        .tint(theme.midground)
        .listRowBackground(theme.card)
        .accessibilityLabel("\(family.id), \(provider.name)")
    }

    /// Toggle binding for one family key: reads the effective set, writes the
    /// materialized + mutated explicit set (and persists it).
    private func bindingFor(key: String) -> Binding<Bool> {
        Binding(
            get: { effectiveVisible.contains(key) },
            set: { isOn in
                var next = effectiveVisible
                if isOn { next.insert(key) } else { next.remove(key) }
                visibleKeys = next
                ModelVisibility.save(next)
            }
        )
    }

    // MARK: - Helpers

    private var effectiveVisible: Set<String> {
        ModelVisibility.effectiveVisibleKeys(stored: visibleKeys, providers: options.providers)
    }

    private var providersWithModels: [ModelProvider] {
        options.providers.filter { !$0.models.isEmpty }
    }

    private var noResults: Bool {
        !search.isEmpty && providersWithModels.allSatisfy { matchingFamilies($0).isEmpty }
    }

    private func matchingFamilies(_ provider: ModelProvider) -> [ModelFamily] {
        let families = ModelVisibility.collapseModelFamilies(provider.models)
        guard !search.isEmpty else { return families }
        let needle = search.lowercased()
        if provider.name.lowercased().contains(needle) || provider.slug.lowercased().contains(needle) {
            return families
        }
        return families.filter { $0.id.lowercased().contains(needle) }
    }
}
