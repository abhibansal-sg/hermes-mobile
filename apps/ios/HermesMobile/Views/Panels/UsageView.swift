import SwiftUI
import Charts

/// Token/cost usage analytics from `GET /api/analytics/usage`: headline totals,
/// a per-day token bar chart (Swift Charts), a per-model breakdown table, and
/// a top-skills table when the server reports skill telemetry.
///
/// A segmented control selects the look-back window (7 / 30 / 90 days) and
/// re-fetches. Read-only.
struct UsageView: View {
    let control: RestClient

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<UsageAnalytics> = .loading
    @State private var days: Int = 30

    private let windows: [Int] = [7, 30, 90]

    init(control: RestClient) {
        self.control = control
    }

    var body: some View {
        List {
            // Range control lives at the top of the content as a real
            // full-width segmented Picker (audit U1) instead of crammed into the
            // nav bar; it stays visible across loading so the nav bar is title-only.
            Section {
                Picker("Window", selection: $days) {
                    ForEach(windows, id: \.self) { Text("\($0) days").tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            content
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .refreshable { await load() }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: days) { Task { await load() } }
        .task { await load() }
    }

    /// State-driven body below the range picker. The loading case is a *labeled*
    /// ProgressView (audit U1) so the panel never reads as a broken bare spinner.
    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            Section {
                ProgressView("Loading usage\u{2026}")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
            }
        case .failed(let message):
            Section {
                ContentUnavailableView {
                    Label("Couldn’t load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
                .listRowBackground(Color.clear)
            }
        case .loaded(let usage):
            // ABH-77: empty state when the period has zero API calls
            let hasAny = (usage.totals.totalApiCalls ?? 0) > 0
                || !usage.daily.isEmpty
                || !usage.byModel.isEmpty
            if !hasAny {
                Section {
                    ContentUnavailableView {
                        Label("No usage yet", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("Start a session and come back to see stats for the last \(days) days.")
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                totalsSection(usage.totals)
                chartSection(usage.daily)
                modelsSection(usage.byModel)
                skillsSection(usage.skills)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func totalsSection(_ totals: UsageTotals) -> some View {
        Section("Totals") {
            metricRow("Input tokens", value: totals.totalInput.map(PanelFormat.compact))
            metricRow("Output tokens", value: totals.totalOutput.map(PanelFormat.compact))
            metricRow("Cache reads", value: totals.totalCacheRead.map(PanelFormat.compact))
            metricRow("Reasoning tokens", value: totals.totalReasoning.map(PanelFormat.compact))
            metricRow("Sessions", value: totals.totalSessions.map(String.init))
            metricRow("API calls", value: totals.totalApiCalls.map(String.init))
            // Hide $0.0000 estimated-cost row when zero (ABH-77 + UX polish)
            if let cost = totals.totalEstimatedCost, cost > 0 {
                LabeledContent("Estimated cost", value: PanelFormat.currency(cost))
                    .fontWeight(.semibold)
            }
            if let actual = totals.totalActualCost, actual > 0 {
                LabeledContent("Actual cost", value: PanelFormat.currency(actual))
            }
        }
    }

    @ViewBuilder
    private func metricRow(_ label: String, value: String?) -> some View {
        if let value {
            LabeledContent(label, value: value)
        }
    }

    @ViewBuilder
    private func chartSection(_ daily: [UsageDay]) -> some View {
        if !daily.isEmpty {
            let totalTokens = daily.reduce(0) { $0 + $1.totalTokens }
            Section {
                Chart(daily) { day in
                    BarMark(
                        x: .value("Day", chartDate(day.day)),
                        y: .value("Tokens", day.totalTokens)
                    )
                    .foregroundStyle(theme.midground.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) {
                                Text(PanelFormat.compact(tokens))
                            }
                        }
                    }
                }
                .frame(height: 200)
                .padding(.vertical, 6)
                // Provide a meaningful label and value so VoiceOver announces
                // the chart and its summary totals.
                .accessibilityLabel("Token usage chart")
                .accessibilityValue("\(PanelFormat.compact(totalTokens)) total tokens across \(daily.count) days")
            } header: {
                HStack {
                    Text("Tokens per day")
                    Spacer()
                    // Legend: shows three buckets (input, output, cache)
                    HStack(spacing: 8) {
                        legendDot(theme.midground, "In+Cache")
                    }
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
                }
            } footer: {
                Text("Input, output, and cache-read tokens included.")
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
            }
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            // The colored circle is purely decorative; VoiceOver reads the text label.
            Circle().fill(color).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(label)
        }
    }

    @ViewBuilder
    private func modelsSection(_ models: [UsageModel]) -> some View {
        if !models.isEmpty {
            Section("By model") {
                ForEach(models) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.model)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 12) {
                            statLabel("\(PanelFormat.compact(model.totalTokens)) tok", "number")
                            if let sessions = model.sessions {
                                statLabel("\(sessions)", "bubble.left")
                            }
                            // Hide $0.0000 model-level cost rows when zero
                            if let cost = model.estimatedCost, cost > 0 {
                                statLabel(PanelFormat.currency(cost), "dollarsign.circle")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func skillsSection(_ skills: UsageSkills?) -> some View {
        if let skills, let top = skills.topSkills, !top.isEmpty {
            Section("Top skills") {
                if let summary = skills.summary {
                    HStack(spacing: 16) {
                        if let loads = summary.totalSkillLoads {
                            summaryStat("\(loads)", "Loads")
                        }
                        if let distinct = summary.distinctSkillsUsed {
                            summaryStat("\(distinct)", "Distinct")
                        }
                        if let actions = summary.totalSkillActions {
                            summaryStat("\(actions)", "Actions")
                        }
                    }
                    .padding(.vertical, 2)
                }
                ForEach(top) { skill in
                    LabeledContent(skill.name ?? "—", value: skill.count.map(String.init) ?? "—")
                }
            }
        }
    }

    private func statLabel(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).labelStyle(.titleAndIcon)
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline)
            Text(label).font(.caption2).foregroundStyle(theme.mutedFg)
        }
    }

    // MARK: Helpers

    /// Parse the `daily[].day` value ("YYYY-MM-DD" from SQLite `date()`).
    private func chartDate(_ day: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: day) ?? Date()
    }

    private func load() async {
        if phase.value == nil { phase = .loading }
        do {
            phase = .loaded(try await control.usageAnalytics(days: days))
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
