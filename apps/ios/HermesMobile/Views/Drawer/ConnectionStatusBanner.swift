import SwiftUI

/// A slim status banner shown directly under the chat nav bar when the
/// connection is degraded. Quiet-when-nominal: it renders nothing while
/// `.connected` (or `.connecting`/`.needsSetup`), an amber strip while
/// `.reconnecting`, and a red strip with a retry button while `.offline`.
///
/// Replaces the old `ConnectionStatusPill` (removed from toolbars entirely per
/// the contract). On-fill text uses `background.contrastingForeground` (ABH-78)
/// so it stays ≥4.5:1 (WCAG AA) over each theme's `statusWarn`/`statusError`
/// color — the literal `.white` measured as low as 1.41:1 on some themes.
struct ConnectionStatusBanner: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        switch connection.phase {
        case .reconnecting(let attempt):
            banner(
                text: attempt == 0 ? "Reconnecting…" : "Reconnecting… (\(attempt))",
                systemImage: "arrow.triangle.2.circlepath",
                background: theme.statusWarn,
                showRetry: false,
                reason: nil
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        case .offline(let reason):
            banner(
                text: "Offline",
                systemImage: "exclamationmark.circle.fill",
                background: theme.statusError,
                showRetry: true,
                reason: reason
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        case .connected, .connecting, .hydrating, .needsSetup:
            // `.hydrating` is owned by the branded loading screen (ABH-82);
            // RootView never shows the chat shell (or this banner) during it.
            EmptyView()
        }
    }

    private func banner(
        text: String,
        systemImage: String,
        background: Color,
        showRetry: Bool,
        reason: String?
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.85)
            }
            Spacer(minLength: 0)
            if showRetry {
                Button {
                    retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry connection")
            }
        }
        .foregroundStyle(background.contrastingForeground)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityBannerLabel(text: text, reason: reason))
    }

    /// Builds a VoiceOver label summarising the banner: status text + optional
    /// reason, so screen-reader users hear the full connection state in one
    /// announcement without traversing the individual icon/text/reason children.
    private func accessibilityBannerLabel(text: String, reason: String?) -> String {
        var parts = [text]
        if let reason, !reason.isEmpty {
            parts.append(reason)
        }
        return parts.joined(separator: ": ")
    }

    /// Re-issue `configure` against the saved server + token (Keychain), exactly
    /// as the retired status pill did, so an offline tap reconnects.
    private func retry() {
        Task {
            guard let url = URL(string: connection.serverURLString),
                  let host = url.host, !host.isEmpty,
                  let token = KeychainService.loadToken(server: connection.serverURLString) else {
                return
            }
            _ = await connection.configure(urlString: connection.serverURLString, token: token)
        }
    }
}
