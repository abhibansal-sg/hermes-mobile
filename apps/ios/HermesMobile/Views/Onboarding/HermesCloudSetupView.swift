import SwiftUI

struct HermesCloudSetupView: View {
    private static let portalURL = URL(string: "https://portal.nousresearch.com")!

    @Environment(ConnectionStore.self) private var connection
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var agents: [CloudAgent] = []
    @State private var organizations: [CloudOrganization] = []
    @State private var selectedAgent: CloudAgent?
    @State private var showingPortalLogin = false
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Finding your agents…")
                } else if !organizations.isEmpty {
                    List(organizations) { organization in
                        Button(organization.name) {
                            discover(organization: organization.slug ?? organization.id)
                        }
                    }
                } else if !agents.isEmpty {
                    List(agents) { agent in
                        Button {
                            selectedAgent = agent
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(agent.name)
                                    .foregroundStyle(theme.fg)
                                Text(agent.dashboardGatewayState)
                                    .font(.caption)
                                    .foregroundStyle(theme.mutedFg)
                            }
                        }
                        .disabled(agent.dashboardURL == nil)
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView {
                        Label("Hermes Cloud", systemImage: "cloud")
                    } description: {
                        Text(errorText ?? "No provisioned agents were found.")
                    } actions: {
                        Button("Sign in") { showingPortalLogin = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .navigationTitle("Hermes Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { discover() }
            .sheet(isPresented: $showingPortalLogin) {
                GatewayWebLoginView(
                    baseURL: Self.portalURL,
                    kind: .portal
                ) {
                    discover()
                }
            }
            .sheet(item: $selectedAgent) { agent in
                if let dashboardURL = agent.dashboardURL {
                    GatewayWebLoginView(
                        baseURL: dashboardURL,
                        kind: .gateway(interactive: false)
                    ) {
                        connect(to: dashboardURL)
                    }
                }
            }
        }
        .hermesThemed(themeStore)
    }

    private func discover(organization: String? = nil) {
        isLoading = true
        errorText = nil
        organizations = []
        Task {
            do {
                let result = try await CloudDiscoveryClient.discover(
                    portalURL: Self.portalURL,
                    organization: organization
                )
                agents = result.agents
                organizations = result.organizations
                isLoading = false
            } catch CloudDiscoveryError.unauthorized {
                isLoading = false
                showingPortalLogin = true
            } catch {
                isLoading = false
                errorText = error.localizedDescription
            }
        }
    }

    private func connect(to dashboardURL: URL) {
        Task {
            connection.connectionMode = .hermesCloud
            await connection.configureAuthenticatedSession(
                urlString: dashboardURL.absoluteString
            )
            if connection.phase == .connected {
                dismiss()
            } else {
                if case .offline(let reason) = connection.phase {
                    errorText = reason ?? "Could not connect to this agent."
                } else {
                    errorText = "Could not connect to this agent."
                }
            }
        }
    }
}

private struct CloudAgent: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let dashboardUrl: String?
    let dashboardGatewayState: String

    var dashboardURL: URL? {
        dashboardUrl.flatMap(URL.init(string:))
    }
}

private struct CloudOrganization: Decodable, Identifiable {
    let id: String
    let slug: String?
    let name: String
}

private struct CloudDiscoveryResult {
    let agents: [CloudAgent]
    let organizations: [CloudOrganization]
}

private enum CloudDiscoveryError: LocalizedError {
    case unauthorized
    case response(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Your Hermes Cloud session has expired."
        case .response(let code):
            return "Hermes Cloud returned HTTP \(code)."
        }
    }
}

private enum CloudDiscoveryClient {
    static func discover(
        portalURL: URL,
        organization: String?
    ) async throws -> CloudDiscoveryResult {
        var components = URLComponents(
            url: portalURL.appendingPathComponent("api/agents"),
            resolvingAgainstBaseURL: false
        )!
        if let organization {
            components.queryItems = [URLQueryItem(name: "org", value: organization)]
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDiscoveryError.response(0)
        }
        if http.statusCode == 401 {
            throw CloudDiscoveryError.unauthorized
        }
        if http.statusCode == 409 {
            struct OrganizationChoice: Decodable {
                let error: String
                let orgs: [CloudOrganization]
            }
            let choice = try JSONDecoder().decode(OrganizationChoice.self, from: data)
            if choice.error == "org_selection_required" {
                return CloudDiscoveryResult(agents: [], organizations: choice.orgs)
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudDiscoveryError.response(http.statusCode)
        }
        struct Envelope: Decodable {
            let agents: [CloudAgent]
        }
        return CloudDiscoveryResult(
            agents: try JSONDecoder().decode(Envelope.self, from: data).agents,
            organizations: []
        )
    }
}
