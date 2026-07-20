import SwiftUI

/// The "New Project" sheet (fix b) — create a project from the Projects tab.
///
/// A deliberately small form: a name field + a root-folder path field (the
/// project is created on the *Mac* gateway, so the path is a Mac filesystem
/// path). On submit it calls the injected `create` closure — which routes
/// through ``ProjectsStore/createProject(name:root:)`` → the plugin
/// `POST /projects` route → the stock `hermes_cli.projects_db.create_project`
/// (ZERO core patch) — and on success hands the created ``Project`` back to the
/// caller (which refreshes + opens it) and dismisses.
///
/// Design language matches the drawer: theme-tokened surfaces, the same
/// `midground` brand accent used by the New-chat capsule, honest inline error +
/// in-flight states, and no gratuitous motion. Reduce Motion is respected (no
/// custom animations here) and every control carries an accessibility
/// identifier/label for VoiceOver + UI tests.
struct NewProjectSheet: View {
    /// A sensible default for the root field — typically the parent directory of
    /// an existing project (where the user's repos already live). Empty when
    /// there are no known projects yet.
    let defaultRoot: String

    /// Perform the create. Returns the created project on success, or a
    /// human-readable failure message. Never throws (matches
    /// ``ProjectsStore/CreateResult``).
    let create: (_ name: String, _ root: String) async -> ProjectsStore.CreateResult

    /// Called with the created project after a successful create (the caller
    /// refreshes the list + opens it). The sheet dismisses itself.
    let onCreated: (Project) -> Void

    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var root: String = ""
    @State private var errorMessage: String?
    @State private var isCreating = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, root }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCreating
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    field(
                        title: "Name",
                        placeholder: "My Project",
                        text: $name,
                        field: .name,
                        identifier: "newProjectName",
                        submitLabel: .next,
                        keyboardHint: nil
                    )

                    field(
                        title: "Root folder",
                        placeholder: "/Users/you/code/my-project",
                        text: $root,
                        field: .root,
                        identifier: "newProjectRoot",
                        submitLabel: .done,
                        keyboardHint: "The folder on your Mac where this project lives. Sessions started under it are grouped here."
                    )

                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                }
                .padding(20)
            }
            .background(theme.listBg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("newProjectCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Create") { Task { await submit() } }
                            .fontWeight(.semibold)
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("newProjectCreate")
                    }
                }
            }
        }
        .hermesThemed(themeStore)
        .onAppear {
            if root.isEmpty { root = defaultRoot }
            focusedField = .name
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func field(
        title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        identifier: String,
        submitLabel: SubmitLabel,
        keyboardHint: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.mutedFg)

            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: field)
                .submitLabel(submitLabel)
                .font(.body)
                .foregroundStyle(theme.fg)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(theme.input, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
                .onSubmit {
                    if field == .name {
                        focusedField = .root
                    } else if canSubmit {
                        Task { await submit() }
                    }
                }

            if let keyboardHint {
                Text(keyboardHint)
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(theme.destructive)
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.destructive.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("newProjectError")
    }

    // MARK: - Action

    private func submit() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedRoot.isEmpty else { return }
        isCreating = true
        errorMessage = nil
        let result = await create(trimmedName, trimmedRoot)
        isCreating = false
        switch result {
        case .created(let project):
            onCreated(project)
            dismiss()
        case .failure(let message):
            errorMessage = message
        }
    }
}
