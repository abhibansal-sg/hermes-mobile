import SwiftUI

/// Read-only mobile Learning Journey: a reverse-chronological view of the
/// `learning.frames` buckets with drill-in through `learning.detail`.
struct LearningJourneyView: View {
    let client: HermesGatewayClient

    @Environment(\.hermesTheme) private var theme
    @State private var phase: PanelPhase<LearningJourneyData> = .loading

    var body: some View {
        PanelContent(phase: phase, label: "Loading learning journey\u{2026}", retry: { Task { await load() } }) { data in
            List {
                if !data.summary.isEmpty {
                    Section {
                        ForEach(data.summary, id: \.self) { line in
                            Text(line)
                                .font(.subheadline)
                                .foregroundStyle(theme.mutedFg)
                        }
                        if let axis = data.axis {
                            LabeledContent("Range", value: "\(axis.start) → \(axis.end)")
                                .font(.caption)
                                .foregroundStyle(theme.mutedFg)
                        }
                    }
                    .listRowBackground(theme.card)
                }

                if data.items.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No learning yet", systemImage: "sparkles")
                        } description: {
                            Text("As Hermes learns memories and reusable skills, they’ll appear here in reverse chronological order.")
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Timeline") {
                        ForEach(data.items) { item in
                            NavigationLink {
                                LearningJourneyDetailView(client: client, item: item)
                            } label: {
                                LearningJourneyRow(item: item)
                            }
                            .listRowBackground(theme.card)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .refreshable { await load() }
        }
        .navigationTitle("Learning Journey")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        if phase.value == nil { phase = .loading }
        do {
            phase = .loaded(try await client.learningFrames().journeyData)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

private struct LearningJourneyRow: View {
    let item: LearningJourneyItem

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Circle()
                    .fill(color(from: item.bucketColor) ?? theme.midground)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Rectangle()
                    .fill(theme.mutedFg.opacity(0.28))
                    .frame(width: 2, height: 36)
                    .accessibilityHidden(true)
            }
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.node.glyph)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.node.isMemory ? theme.midground : theme.fg)
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .lineLimit(2)
                }

                Text(item.subtitle)
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(2)

                Text("\(item.bucketDate) · \(item.bucketLabel)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.mutedFg)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.node.kindLabel), \(item.title), \(item.bucketDate)")
    }

    private func color(from hex: String?) -> Color? {
        guard let hex else { return nil }
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

private struct LearningJourneyDetailView: View {
    let client: HermesGatewayClient
    let item: LearningJourneyItem

    @Environment(\.hermesTheme) private var theme
    @State private var phase: PanelPhase<LearningNodeDetail> = .loading

    var body: some View {
        PanelContent(phase: phase, label: "Loading detail\u{2026}", retry: { Task { await load() } }) { detail in
            List {
                Section("What") {
                    Text(detail.content?.isEmpty == false ? detail.content! : (item.node.body ?? item.title))
                        .font(.body)
                        .textSelection(.enabled)
                }
                .listRowBackground(theme.card)

                Section("When") {
                    LabeledContent("Bucket", value: item.bucketLabel)
                    LabeledContent("Date", value: item.bucketDate)
                    LabeledContent("Timeline", value: item.node.meta)
                }
                .listRowBackground(theme.card)

                Section("Source") {
                    LabeledContent("Type", value: (detail.kind ?? item.node.kindLabel).capitalized)
                    LabeledContent("Node", value: detail.label ?? item.title)
                    LabeledContent("ID", value: detail.id ?? item.id)
                        .font(.caption)
                }
                .listRowBackground(theme.card)

                if detail.ok == false, let message = detail.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .listRowBackground(theme.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .refreshable { await load() }
        }
        .navigationTitle(item.node.kindLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        if phase.value == nil { phase = .loading }
        do {
            phase = .loaded(try await client.learningDetail(id: item.id))
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
