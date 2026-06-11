import SwiftUI

/// The Hermes app icon as a self-resolving brand glyph, shared by the first-run
/// ``WelcomeView`` (ABH-75) and the post-connect ``HydrationLoadingView``
/// (ABH-82). Both surfaces show the same 96pt rounded-corner brand mark, so the
/// resolver and the chrome live in one place rather than being copied per view.
///
/// The icon asset is `universal`/1024 and is NOT guaranteed to resolve via
/// `Image(_:)` on every build, so this degrades gracefully to a themed terminal
/// glyph when the bundle image is unavailable (the same fallback the welcome
/// brand moment shipped with).
struct BrandAppIcon: View {
    @Environment(\.hermesTheme) private var theme

    /// The rendered side length. Defaults to the 96pt brand-moment size used by
    /// both call sites; exposed so future surfaces can scale it.
    var size: CGFloat = 96

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .accessibilityHidden(true)
    }

    /// The bundled icon image if it resolves, otherwise a themed terminal glyph
    /// on the brand accent (graceful degradation — see ``Self/bundledAppIcon``).
    @ViewBuilder
    private var glyph: some View {
        if let icon = Self.bundledAppIcon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                theme.midground
                Image(systemName: "terminal.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(theme.midground.contrastingForeground)
            }
        }
    }

    /// Resolve the primary app icon from the bundle's `CFBundleIcons`, with a
    /// direct asset-name fallback. Computed once; `nil` when unavailable.
    static let bundledAppIcon: UIImage? = {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let lastName = files.last,
           let image = UIImage(named: lastName) {
            return image
        }
        return UIImage(named: "AppIcon")
    }()
}
