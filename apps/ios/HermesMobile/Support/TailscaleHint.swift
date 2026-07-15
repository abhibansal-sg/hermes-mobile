import SwiftUI
import UIKit

/// Detects the common "I can't reach my tailnet host because Tailscale isn't
/// running" failure mode and produces a small, dismissible hint banner.
///
/// The gateway is usually reached over Tailscale Serve at a `*.ts.net` hostname.
/// When the VPN is down, every connection attempt to that host fails with an
/// opaque transport error; this helper turns that situation into actionable
/// guidance ("Is Tailscale connected?") with a button that deep-links into the
/// Tailscale app.
///
/// It is a pure value type with no dependencies on the networking layer — feed
/// it the configured server URL string and (optionally) the failure reason that
/// `ConnectionStore.phase`'s `.offline(String?)` already carries. ``make(...)``
/// returns `nil` unless the host is a tailnet host, so the banner only appears
/// where the advice is relevant.
struct TailscaleHint: Equatable, Identifiable {
    let id = UUID()
    /// The `*.ts.net` host the user is trying to reach (for the banner subtitle).
    let host: String

    var title: String { "Can't reach your tailnet" }

    var message: String {
        "Hermes is hosted on \(host) over Tailscale. If you're offline, make sure Tailscale is connected on this device."
    }

    /// Deep link into the Tailscale app. Opening requires the `tailscale` scheme
    /// in `LSApplicationQueriesSchemes` (see `integrationNotes`).
    static let tailscaleURL = URL(string: "tailscale://")!

    static func == (lhs: TailscaleHint, rhs: TailscaleHint) -> Bool {
        lhs.host == rhs.host
    }

    /// Build a hint for an offline situation, or `nil` when it doesn't apply.
    ///
    /// - Parameters:
    ///   - serverURLString: the configured gateway base URL (e.g.
    ///     `ConnectionStore.serverURLString`).
    ///   - failureReason: the reason from `.offline(String?)`, if any. Only used
    ///     to decide relevance for *non*-`.ts.net` hosts (see below); a tailnet
    ///     host always qualifies because its dominant failure mode is the VPN.
    /// - Returns: a ``TailscaleHint`` when the configured host is a tailnet host;
    ///   otherwise `nil`.
    ///
    /// We key purely on the host suffix rather than trying to pattern-match error
    /// text (which varies by `NSURLError` code and locale). A failed connection
    /// to a `*.ts.net` host is, in practice, almost always Tailscale being down.
    static func make(serverURLString: String, failureReason: String? = nil) -> TailscaleHint? {
        guard let host = host(from: serverURLString), isTailnetHost(host) else {
            return nil
        }
        return TailscaleHint(host: host)
    }

    /// Whether `host` is a Tailscale MagicDNS hostname (`*.ts.net`,
    /// case-insensitive). Plain `ts.net` with no subdomain does not qualify.
    static func isTailnetHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered.hasSuffix(".ts.net") && lowered != ".ts.net"
    }

    /// Extract the host from a URL string, tolerating a missing scheme by
    /// retrying with an `https://` prefix (so a user who typed
    /// `my-box.tail1234.ts.net` is still recognised).
    private static func host(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        if let url = URL(string: "https://\(trimmed)"), let host = url.host, !host.isEmpty {
            return host
        }
        return nil
    }
}

/// Banner presenting a ``TailscaleHint`` with an "Open Tailscale" action and a
/// dismiss control. Place it above the chat/session content when
/// `ConnectionStore.phase` is `.offline` and ``TailscaleHint/make(...)`` returns
/// non-nil.
struct TailscaleHintBanner: View {
    let hint: TailscaleHint
    /// Invoked when the user dismisses the banner (e.g. clears the binding that
    /// gates it).
    var onDismiss: () -> Void = {}

    @Environment(\.openURL) private var openURL
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "network.slash")
                .font(.title3)
                .foregroundStyle(theme.statusWarn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(hint.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                Text(hint.message)
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    openTailscale()
                } label: {
                    Label("Open Tailscale", systemImage: "arrow.up.forward.app")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(theme.midground)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.mutedFg)
            }
            .accessibilityLabel("Dismiss Tailscale hint")
        }
        .padding(12)
        .background(theme.statusWarn.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.statusWarn.opacity(0.3))
        )
        .padding(.horizontal)
    }

    /// Open the Tailscale app. Falls back to the App Store page if Tailscale is
    /// not installed (the deep link can't be opened), so the hint stays useful
    /// for someone who hasn't set Tailscale up yet.
    private func openTailscale() {
        if UIApplication.shared.canOpenURL(TailscaleHint.tailscaleURL) {
            openURL(TailscaleHint.tailscaleURL)
        } else if let appStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") {
            openURL(appStore)
        }
    }
}
