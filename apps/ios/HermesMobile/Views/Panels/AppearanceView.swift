import SwiftUI

/// Theme picker. Self-contained: takes a ``ThemeStore`` and writes the selection
/// straight through it (which persists to UserDefaults). Each row shows the
/// theme's label, a five-swatch preview strip, and a checkmark on the active
/// theme. Selecting a row re-skins the whole app immediately via the store.
///
/// Presentation-agnostic (Batch B): provides no `NavigationStack` and no "Done"
/// of its own — it is pushed onto the hosting Settings stack, which supplies the
/// themed nav bar and back button. Selecting a row re-skins the app live; because
/// the host re-resolves `.hermesThemed`, the picker repaints in the new palette.
struct AppearanceView: View {
    @Bindable var store: ThemeStore

    @Environment(\.hermesTheme) private var theme

    init(store: ThemeStore) {
        self.store = store
    }

    var body: some View {
        List {
            Section {
                ForEach(store.presets) { preset in
                    ThemeRow(
                        themeSet: preset,
                        theme: store.previewTheme(for: preset),
                        isSelected: preset.name == store.selection
                    ) {
                        store.select(preset.name)
                    }
                }
            } footer: {
                Text("\"Nous\" follows your system appearance. The other themes are dark-only.")
                    .foregroundStyle(theme.mutedFg)
            }
        }
        // PSF-01: prevent the list from rendering the system material background
        // behind dark palette rows (the theme card/bg would show through correctly
        // on all six themes once the default inset-grouped material is suppressed).
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Row

private struct ThemeRow: View {
    let themeSet: HermesThemeSet
    let theme: HermesTheme
    let isSelected: Bool
    let onSelect: () -> Void

    /// True for the five forced-dark presets; false for adaptive "Nous".
    private var isDarkOnly: Bool { themeSet.forcedColorScheme == .dark }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(theme.label)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(theme.fg)
                        if isDarkOnly {
                            Text("Dark only")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.mutedFg)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.mutedFg.opacity(0.15), in: Capsule())
                                .accessibilityHidden(true)
                        }
                    }
                    SwatchStrip(colors: theme.swatches, border: theme.border)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.midground)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? theme.accent : theme.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isDarkOnly ? "\(theme.label), Dark only" : theme.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Swatches

/// Five contiguous color chips that read the palette's mood at a glance:
/// surface, brand, card, primary, accent.
private struct SwatchStrip: View {
    let colors: [Color]
    let border: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Rectangle()
                    .fill(color)
                    .frame(width: 34, height: 18)
                    // Hairline between chips so near-identical surface tokens
                    // (bg vs card differ by a few %) still read as distinct
                    // swatches on every theme (contract: "read well on all 6").
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Rectangle()
                                .fill(border)
                                .frame(width: 1)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}
