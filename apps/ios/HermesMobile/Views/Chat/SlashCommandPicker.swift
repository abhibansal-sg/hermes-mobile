import SwiftUI

struct SlashCommandPicker: View {
    let sections: [SlashCommandSection]
    let isLoading: Bool
    let onSelect: (SlashCommandItem) -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && sections.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading commands…")
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            if !section.name.isEmpty {
                                Text(section.name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(theme.mutedFg)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(section.commands.prefix(8)) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(item.display)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(theme.fg)
                                            .lineLimit(1)
                                            .monospaced()
                                        if !item.summary.isEmpty {
                                            Text(item.summary)
                                                .font(.caption)
                                                .foregroundStyle(theme.mutedFg)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Slash command \(item.display)")
                                .accessibilityValue(item.summary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 3)
        .accessibilityIdentifier("slashCommandPicker")
    }
}
