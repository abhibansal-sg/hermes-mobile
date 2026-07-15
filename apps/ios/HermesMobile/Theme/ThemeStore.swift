import SwiftUI

/// Holds the user's theme selection and resolves it to a concrete ``HermesTheme``.
///
/// Mirrors the ``AppLock`` pattern: `@Observable`/`@MainActor`, no back-references
/// and no networking, built once in `AppEnvironment.init` and injected by
/// `HermesMobileApp`. Selection persists in UserDefaults under
/// ``DefaultsKeys/theme`` (default `"nous"`).
///
/// `nous` is adaptive (light + dark pair); the other five are single dark
/// palettes that force `.dark`. The view layer feeds the live system color
/// scheme in via ``setSystemColorScheme(_:)`` (from an `@Environment(\.colorScheme)`
/// read at the root) so the adaptive set resolves to the right variant.
@MainActor
@Observable
final class ThemeStore {
    /// Persisted theme name. Writing it through the setter keeps the resolved
    /// ``current`` in step (UserDefaults is not touched directly elsewhere).
    var selection: String {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection, forKey: DefaultsKeys.theme)
        }
    }

    /// The live system color scheme, mirrored from the root view's
    /// `@Environment(\.colorScheme)`. Only the adaptive `nous` set reads it.
    private(set) var systemColorScheme: ColorScheme = .light

    init() {
        let saved = UserDefaults.standard.string(forKey: DefaultsKeys.theme)
        // Validate against the registry so a retired name falls back to nous.
        if let saved, HermesThemePresets.all.contains(where: { $0.name == saved }) {
            self.selection = saved
        } else {
            self.selection = HermesThemePresets.defaultName
        }
    }

    // MARK: - Selection

    /// The currently selected set (carries the optional dark variant + the
    /// forced scheme for single-palette themes).
    var currentSet: HermesThemeSet {
        HermesThemePresets.set(named: selection)
    }

    /// The resolved palette for the current selection and system scheme. This is
    /// what every surface paints with.
    var current: HermesTheme {
        currentSet.resolved(for: systemColorScheme)
    }

    /// The scheme the root must pin to: `nil` for the adaptive set (follow the
    /// system), `.dark` for the forced single-palette themes. Drives
    /// `.preferredColorScheme` at the app root.
    var forcedColorScheme: ColorScheme? {
        currentSet.forcedColorScheme
    }

    /// Sets and persists the selection. Used by the picker UI.
    func select(_ name: String) {
        guard HermesThemePresets.all.contains(where: { $0.name == name }) else { return }
        selection = name
    }

    /// Feed the live system scheme from the view layer so the adaptive set
    /// resolves correctly. A no-op when unchanged (keeps Observation quiet).
    func setSystemColorScheme(_ scheme: ColorScheme) {
        guard scheme != systemColorScheme else { return }
        systemColorScheme = scheme
    }

    // MARK: - Picker data

    /// Every available set, in picker order.
    var presets: [HermesThemeSet] { HermesThemePresets.all }

    /// Resolve a set for preview/swatch display against the current system
    /// scheme (so the adaptive row previews the variant the user would see).
    func previewTheme(for set: HermesThemeSet) -> HermesTheme {
        set.resolved(for: systemColorScheme)
    }
}
