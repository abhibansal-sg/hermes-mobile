import SwiftUI

// MARK: - Environment key

private struct HermesThemeKey: EnvironmentKey {
    /// Default to the resolved light `nous` palette so previews and any surface
    /// that forgets to re-install the theme still get a sane (non-crashing)
    /// value rather than an empty one.
    static let defaultValue: HermesTheme = HermesThemePresets.nousLight
}

extension EnvironmentValues {
    /// The resolved palette for the current surface. Re-installed at every
    /// NavigationStack/sheet root via ``hermesThemed(_:)`` because SwiftUI sheets
    /// do not reliably inherit custom `EnvironmentValues` across presentation.
    var hermesTheme: HermesTheme {
        get { self[HermesThemeKey.self] }
        set { self[HermesThemeKey.self] = newValue }
    }
}

// MARK: - One-modifier theming helper

/// Bundles the three things every themed root needs into a single modifier so
/// migrators apply ONE thing at each sheet/stack root:
///
///   1. `\.hermesTheme` — the resolved palette in the environment.
///   2. `.tint(theme.midground)` — the global brand accent (fixes "half-skinned").
///   3. `.preferredColorScheme(store.forcedColorScheme)` — pins single-palette
///      themes to `.dark` so system chrome matches.
///
/// It also mirrors the live system scheme back into the store on appear/change so
/// the adaptive `nous` set resolves to the right variant.
///
/// Usage at every sheet / NavigationStack root:
/// ```swift
/// SettingsSheet()
///     .hermesThemed(themeStore)
/// ```
private struct HermesThemedModifier: ViewModifier {
    let store: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.hermesTheme, store.current)
            .tint(store.current.midground)
            .preferredColorScheme(store.forcedColorScheme)
            .onAppear { store.setSystemColorScheme(colorScheme) }
            .onChange(of: colorScheme) { _, newScheme in
                store.setSystemColorScheme(newScheme)
            }
    }
}

extension View {
    /// Apply the resolved theme (environment value + brand tint + forced color
    /// scheme) at a NavigationStack or sheet root. See ``HermesThemedModifier``.
    func hermesThemed(_ store: ThemeStore) -> some View {
        modifier(HermesThemedModifier(store: store))
    }
}
