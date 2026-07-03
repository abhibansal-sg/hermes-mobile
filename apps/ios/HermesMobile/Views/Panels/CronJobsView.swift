import SwiftUI

/// Scheduled (cron) jobs panel from `GET /api/cron/jobs`: name, schedule,
/// enabled/paused state, last run + status, last error. Full CRUD:
///   • "New cron" toolbar button → create sheet
///   • Row tap → edit sheet
///   • Swipe-to-delete + confirmation
///   • Trigger / pause / resume per-row actions
/// Pull-to-refresh re-fetches; success actions fire a haptic and a brief toast.
struct CronJobsView: View {
    let control: RestClient

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<[CronJob]> = .loading
    /// Job ids with an in-flight action, for per-row spinners.
    @State private var pending: Set<String> = []
    @State private var actionError: String?
    @State private var toast: String?

    /// Editor sheet state.
    @State private var editorJob: CronJob? = nil   // nil = create, non-nil = edit
    @State private var showEditor = false

    /// Delete confirmation.
    @State private var pendingDelete: CronJob?
    @State private var showDeleteConfirm = false

    init(control: RestClient) {
        self.control = control
    }

    var body: some View {
        PanelContent(phase: phase, label: "Loading jobs\u{2026}", retry: { Task { await load() } }) { jobs in
            ZStack(alignment: .bottom) {
                List {
                    // Top entry point: navigate to the flat Automation Runs feed.
                    // Uses NavigationLink(destination:) so it pushes within the
                    // SettingsView NavigationStack — the standard panel nav pattern.
                    Section {
                        NavigationLink(destination: AutomationRunsView(rest: control)) {
                            Label("Recent runs", systemImage: "list.bullet.clock")
                        }
                        .accessibilityIdentifier("cronRecentRunsLink")
                    }
                    .listRowBackground(theme.card)

                    if jobs.isEmpty {
                        ContentUnavailableView {
                            Label("No scheduled jobs", systemImage: "clock.badge.xmark")
                        } description: {
                            Text("Tap \u{201C}New cron\u{201D} to create your first scheduled job.")
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(jobs) { job in
                            CronJobRow(
                                job: job,
                                isPending: pending.contains(job.id),
                                onTap: {
                                    editorJob = job
                                    showEditor = true
                                },
                                onTrigger: { Task { await act(job.id, toast: "Job triggered") {
                                    try await control.triggerCronJob(id: job.id)
                                } } },
                                onPause: { Task { await act(job.id, toast: "Job paused") {
                                    try await control.pauseCronJob(id: job.id)
                                } } },
                                onResume: { Task { await act(job.id, toast: "Job resumed") {
                                    try await control.resumeCronJob(id: job.id)
                                } } }
                            )
                            // PSF-03: cron job rows use theme.card so the list
                            // doesn't fall through to system gray on dark palettes.
                            .listRowBackground(theme.card)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = job
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .foregroundStyle(theme.destructive)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editorJob = job
                                    showEditor = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.accentColor)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(theme.bg)
                .refreshable { await load() }

                if let toast {
                    ToastBanner(message: toast)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.spring(response: 0.3), value: self.toast)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle("Scheduled Jobs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorJob = nil
                    showEditor = true
                } label: {
                    Label("New cron", systemImage: "plus")
                }
                .accessibilityIdentifier("newCronButton")
            }
            // (Release audit: the toolbar "Recent Runs" duplicate was removed —
            // the in-list "Recent runs" row is the single entry point, and a
            // leading toolbar item fights the Back button on this pushed view.)
        }
        .sheet(isPresented: $showEditor) {
            CronEditorSheet(
                control: control,
                existing: editorJob,
                onSaved: { updated in
                    showEditor = false
                    if case .loaded(var jobs) = phase {
                        if let idx = jobs.firstIndex(where: { $0.id == updated.id }) {
                            jobs[idx] = updated
                        } else {
                            jobs.append(updated)
                        }
                        phase = .loaded(jobs)
                    }
                    showToast(editorJob == nil ? "Job created" : "Job updated")
                }
            )
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.name ?? "job")\u{201D}?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let job = pendingDelete else { return }
                Task { await deleteJob(job) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Action failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    // MARK: Actions

    private func load() async {
        if phase.value == nil { phase = .loading }
        do {
            phase = .loaded(try await control.cronJobs())
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Run a mutating action, then splice the returned (updated) job back into
    /// the list so the row reflects the new state without a full reload.
    private func act(_ id: String, toast toastMessage: String, _ operation: @escaping () async throws -> CronJob) async {
        guard !pending.contains(id) else { return }
        pending.insert(id)
        defer { pending.remove(id) }
        do {
            let updated = try await operation()
            if case .loaded(var jobs) = phase,
               let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index] = updated
                phase = .loaded(jobs)
            }
            showToast(toastMessage)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteJob(_ job: CronJob) async {
        pending.insert(job.id)
        defer { pending.remove(job.id) }
        do {
            try await control.deleteCronJob(id: job.id)
            if case .loaded(let jobs) = phase {
                phase = .loaded(jobs.filter { $0.id != job.id })
            }
            pendingDelete = nil
            showToast("Job deleted")
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func showToast(_ message: String) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }
}

// MARK: - Row

private struct CronJobRow: View {
    let job: CronJob
    let isPending: Bool
    let onTap: () -> Void
    let onTrigger: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(theme.fg)
                    Spacer()
                    stateBadge
                }

                if let schedule = job.scheduleDisplay, !schedule.isEmpty {
                    Label(schedule, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                        .labelStyle(.titleAndIcon)
                }

                // Prompt preview (first 80 chars)
                if let prompt = job.prompt, !prompt.isEmpty {
                    Text(String(prompt.prefix(80)) + (prompt.count > 80 ? "\u{2026}" : ""))
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(2)
                }

                if let next = PanelFormat.relative(fromISO: job.nextRunAt), !job.isPaused {
                    Text("Next run \(next)")
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                }

                if let status = job.lastStatus {
                    lastRunLine(status: status, deliveryFailed: deliveryFailed)
                }

                // Last error (ABH-76)
                if let err = job.lastError, !err.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.statusError)
                            .imageScale(.small)
                        Text(err)
                            .lineLimit(2)
                    }
                    .font(.caption2)
                    .foregroundStyle(theme.statusError)
                }

                if let err = deliveryError, deliveryFailed {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "paperplane.circle.fill")
                            .foregroundStyle(theme.statusWarn)
                            .imageScale(.small)
                        Text("Delivery failed: \(err)")
                            .lineLimit(2)
                    }
                    .font(.caption2)
                    .foregroundStyle(theme.statusWarn)
                }

                HStack(spacing: 16) {
                    if isPending {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: onTrigger) {
                            Label("Run now", systemImage: "play.fill")
                        }
                        .accessibilityIdentifier("cronRunNow_\(job.name)")
                        if job.isPaused {
                            Button(action: onResume) {
                                Label("Resume", systemImage: "play.circle")
                            }
                            .accessibilityIdentifier("cronResume_\(job.name)")
                        } else {
                            Button(action: onPause) {
                                Label("Pause", systemImage: "pause.circle")
                            }
                            .accessibilityIdentifier("cronPause_\(job.name)")
                        }
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .labelStyle(.titleAndIcon)
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        // ABH-76: long-press to copy a failing automation's prompt ("what it
        // runs") and last error ("why it failed"). Tap still opens the editor,
        // which shows the full prompt in an editable (copyable) field.
        .contextMenu {
            if let prompt = job.prompt, !prompt.isEmpty {
                Button {
                    UIPasteboard.general.string = prompt
                } label: {
                    Label("Copy prompt", systemImage: "doc.on.doc")
                }
            }
            if let err = job.lastError, !err.isEmpty {
                Button {
                    UIPasteboard.general.string = err
                } label: {
                    Label("Copy error", systemImage: "exclamationmark.triangle")
                }
            }
            if let err = deliveryError {
                Button {
                    UIPasteboard.general.string = err
                } label: {
                    Label("Copy delivery error", systemImage: "paperplane.circle")
                }
            }
        }
    }

    private var deliveryError: String? {
        guard let err = job.lastDeliveryError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !err.isEmpty else {
            return nil
        }
        return err
    }

    private var deliveryFailed: Bool {
        job.lastStatus?.lowercased() == "ok" && deliveryError != nil
    }

    private var stateBadge: some View {
        let paused = job.isPaused
        let tint = paused ? theme.statusWarn : theme.statusOK
        return Label(paused ? "Paused" : "Scheduled",
                     systemImage: paused ? "pause.fill" : "checkmark.circle.fill")
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private func lastRunLine(status: String, deliveryFailed: Bool) -> some View {
        let ok = status.lowercased() == "ok"
        let tint = ok ? (deliveryFailed ? theme.statusWarn : theme.statusOK) : theme.statusError
        let icon = ok ? (deliveryFailed ? "paperplane.circle" : "checkmark.circle") : "exclamationmark.triangle"
        let label = deliveryFailed ? "ok · delivery failed" : status
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            if let when = PanelFormat.relative(fromISO: job.lastRunAt) {
                Text("Last run \(when) \u{2014} \(label)")
            } else {
                Text("Last run: \(label)")
            }
        }
        .font(.caption2)
        .foregroundStyle(deliveryFailed ? theme.statusWarn : theme.mutedFg)
    }
}

// MARK: - Editor sheet

/// Modal sheet for creating or editing a cron job. Fields: name (optional),
/// prompt (required), schedule preset or custom expression, delivery channel.
private struct CronEditorSheet: View {
    let control: RestClient
    /// Non-nil when editing an existing job.
    let existing: CronJob?
    let onSaved: (CronJob) -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var schedulePreset = SchedulePreset.daily
    @State private var customExpr = ""
    @State private var deliver = "local"
    @State private var deliveryTargets: [CronDeliveryTarget] = [.local]
    @State private var deliveryTargetsLoading = true
    @State private var deliveryTargetsError: String?
    @State private var saving = false
    @State private var saveError: String?

    var isEdit: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("cronNameField")
                }

                Section {
                    TextEditor(text: $prompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                        .accessibilityIdentifier("cronPromptField")
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("The task the agent will run on the schedule.")
                }

                Section("Schedule") {
                    Picker("Frequency", selection: $schedulePreset) {
                        ForEach(SchedulePreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .onChange(of: schedulePreset) {
                        if schedulePreset != .custom {
                            customExpr = schedulePreset.expr ?? ""
                        }
                    }

                    if schedulePreset == .custom {
                        TextField("Cron expression (e.g. 0 9 * * *)", text: $customExpr)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .accessibilityIdentifier("cronCustomExprField")
                    } else {
                        HStack {
                            Text(schedulePreset.humanized(expr: effectiveExpr))
                                .font(.subheadline)
                                .foregroundStyle(theme.fg)
                            Spacer()
                            Text(effectiveExpr)
                                .font(.caption.monospaced())
                                .foregroundStyle(theme.mutedFg)
                        }
                    }
                }

                Section {
                    Picker("Deliver to", selection: $deliver) {
                        ForEach(deliveryRows) { target in
                            Text(deliveryLabel(for: target)).tag(target.id)
                        }
                    }
                    .accessibilityIdentifier("cronDeliverPicker")

                    deliveryStateNote
                } header: {
                    Text("Delivery")
                }

                if let err = saveError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.statusError)
                            .font(.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle(isEdit ? "Edit Job" : "New Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Group {
                        if saving {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(isEdit ? "Save" : "Create") { Task { await save() } }
                                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || effectiveExpr.isEmpty)
                                .accessibilityIdentifier("cronSaveButton")
                        }
                    }
                }
            }
            .onAppear {
                prefill()
                Task { await loadDeliveryTargets() }
            }
        }
    }

    private var effectiveExpr: String {
        schedulePreset == .custom ? customExpr : (schedulePreset.expr ?? customExpr)
    }

    private var deliveryRows: [CronDeliveryTarget] {
        var rows = deliveryTargets.isEmpty ? [CronDeliveryTarget.local] : deliveryTargets
        if !rows.contains(where: { $0.id == CronDeliveryTarget.local.id }) {
            rows.insert(.local, at: 0)
        }
        if !deliver.isEmpty, !rows.contains(where: { $0.id == deliver }) {
            rows.append(
                CronDeliveryTarget(
                    id: deliver,
                    name: deliver,
                    homeTargetSet: false,
                    homeEnvVar: nil
                )
            )
        }
        return rows
    }

    private var hasOnlyLocalDeliveryTarget: Bool {
        deliveryRows.filter { $0.id != CronDeliveryTarget.local.id }.isEmpty
    }

    @ViewBuilder
    private var deliveryStateNote: some View {
        if deliveryTargetsLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading live delivery targets\u{2026}")
            }
            .font(.caption)
            .foregroundStyle(theme.mutedFg)
        } else if let deliveryTargetsError {
            Label(
                "Couldn\u{2019}t refresh delivery targets; saving local-only unless this job already had a selected target. \(deliveryTargetsError)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(theme.statusWarn)
        } else if deliveryTargets.isEmpty {
            Label("No delivery targets reported; local save only.", systemImage: "tray")
                .font(.caption)
                .foregroundStyle(theme.mutedFg)
        } else if hasOnlyLocalDeliveryTarget {
            Text("No messaging platforms are connected for cron delivery. Set a home channel before delivering reports to chat.")
                .font(.caption)
                .foregroundStyle(theme.mutedFg)
        }
    }

    private func deliveryLabel(for target: CronDeliveryTarget) -> String {
        if target.id == CronDeliveryTarget.local.id { return target.name }
        let fetchedTargetIds = Set(deliveryTargets.map(\.id))
        if !fetchedTargetIds.contains(target.id) {
            return "\(target.name) \u{2014} unavailable on this gateway"
        }
        if !target.homeTargetSet {
            return "\(target.name) \u{2014} set a home channel first"
        }
        return target.name
    }

    private func loadDeliveryTargets() async {
        deliveryTargetsLoading = true
        deliveryTargetsError = nil
        do {
            deliveryTargets = try await control.cronDeliveryTargets()
        } catch {
            deliveryTargets = [.local]
            deliveryTargetsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        deliveryTargetsLoading = false
    }

    private func prefill() {
        guard let job = existing else { return }
        name = job.name == "Untitled job" ? "" : job.name
        prompt = job.prompt ?? ""
        let rawExpr = job.scheduleDisplay ?? ""
        let preset = SchedulePreset.preset(for: rawExpr)
        schedulePreset = preset
        customExpr = rawExpr
        deliver = job.deliver ?? job.source ?? "local"
    }

    private func save() async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespaces)
        let trimmedExpr = effectiveExpr.trimmingCharacters(in: .whitespaces)
        guard !trimmedPrompt.isEmpty, !trimmedExpr.isEmpty else {
            saveError = "Prompt and schedule are required."
            return
        }
        saving = true
        saveError = nil
        do {
            let saved: CronJob
            if let job = existing {
                saved = try await control.updateCronJob(
                    id: job.id,
                    name: name.trimmingCharacters(in: .whitespaces).nonEmpty,
                    prompt: trimmedPrompt,
                    schedule: trimmedExpr,
                    deliver: deliver
                )
            } else {
                saved = try await control.createCronJob(
                    name: name.trimmingCharacters(in: .whitespaces).nonEmpty,
                    prompt: trimmedPrompt,
                    schedule: trimmedExpr,
                    deliver: deliver
                )
            }
            onSaved(saved)
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        saving = false
    }
}

// MARK: - Schedule presets (humanizer)

private enum SchedulePreset: String, CaseIterable, Identifiable {
    case daily, weekdays, weekly, monthly, hourly, every15, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .hourly: return "Hourly"
        case .every15: return "Every 15 min"
        case .custom: return "Custom\u{2026}"
        }
    }

    var expr: String? {
        switch self {
        case .daily: return "0 9 * * *"
        case .weekdays: return "0 9 * * 1-5"
        case .weekly: return "0 9 * * 1"
        case .monthly: return "0 9 1 * *"
        case .hourly: return "0 * * * *"
        case .every15: return "*/15 * * * *"
        case .custom: return nil
        }
    }

    /// Map a cron expression back to the best-matching preset.
    static func preset(for expr: String) -> SchedulePreset {
        let normalized = expr.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return allCases.first { $0.expr == normalized } ?? .custom
    }

    /// Human-readable description for a given expression under this preset.
    func humanized(expr: String) -> String {
        let parts = expr.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard parts.count == 5 else { return expr }
        let (minute, hour) = (parts[0], parts[1])
        func time() -> String {
            if let h = Int(hour), let m = Int(minute) {
                let d = DateComponents(hour: h, minute: m)
                if let date = Calendar.current.date(from: d) {
                    return date.formatted(.dateTime.hour().minute())
                }
            }
            return "\(hour):\(minute.padLeft(2, "0"))"
        }
        switch self {
        case .daily: return "Every day at \(time())"
        case .weekdays: return "Weekdays at \(time())"
        case .weekly:
            let dayNames = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
            let dayLabel = Int(parts[4]).map { dayNames[safe: $0] ?? parts[4] } ?? parts[4]
            return "Every \(dayLabel) at \(time())"
        case .monthly: return "Monthly on the \(ordinal(parts[2])) at \(time())"
        case .hourly: return minute == "0" ? "Top of every hour" : "Every hour at :\(minute.padLeft(2, "0"))"
        case .every15: return "Every 15 minutes"
        case .custom: return expr
        }
    }

    private func ordinal(_ n: String) -> String {
        guard let i = Int(n) else { return n }
        let suffix: String
        switch i % 10 {
        case 1 where i % 100 != 11: suffix = "st"
        case 2 where i % 100 != 12: suffix = "nd"
        case 3 where i % 100 != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(i)\(suffix)"
    }
}

// MARK: - Toast banner

private struct ToastBanner: View {
    let message: String
    @Environment(\.hermesTheme) private var theme
    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.bg)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(theme.fg.opacity(0.9), in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    func padLeft(_ length: Int, _ pad: Character) -> String {
        String(repeatElement(pad, count: max(0, length - count))) + self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
