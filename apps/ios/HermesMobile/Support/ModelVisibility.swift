import Foundation

// MARK: - Model visibility (ABH-84 follow-up)
//
// Direct port of the desktop's `store/model-visibility.ts` so the two clients
// share semantics:
//   * The user can curate WHICH models show in the session model picker.
//   * Stored as a set of `provider::model` keys (`::` avoids colliding with
//     model ids that contain a single colon, e.g. `model:tag`).
//   * `nil` (never customized) ⇒ the curated default applies: the first
//     `defaultVisiblePerProvider` model FAMILIES of every provider (backend
//     lists are already relevance-ordered).
//   * A base model and its `…-fast` sibling collapse into ONE family row with
//     one visibility toggle (desktop `collapseModelFamilies`).
//
// Persistence is client-local (UserDefaults), exactly like the desktop's
// localStorage — visibility is a per-device display preference, not gateway
// state.

/// A model and its optional `…-fast` sibling, collapsed into one logical row.
/// `id` is the canonical (base) model; `fastId` is the fast variant if present.
struct ModelFamily: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let fastId: String?
}

enum ModelVisibility {
    /// Families shown per provider before the user has customized the list.
    /// Mirrors desktop `DEFAULT_VISIBLE_PER_PROVIDER`.
    static let defaultVisiblePerProvider = 50

    /// UserDefaults key holding the JSON array of visible `provider::model` keys.
    static let defaultsKey = "hermes.visibleModels"

    // MARK: Key

    /// Stable key for a provider/model pair.
    static func key(provider: String, model: String) -> String {
        "\(provider)::\(model)"
    }

    // MARK: Family collapse

    /// Collapse a provider's model list so a base model and its `…-fast`
    /// variant become a single family (one row, one toggle). Order is
    /// preserved by the base model's position. A `…-fast` model with no base
    /// stands on its own. Matching is case-insensitive throughout (the
    /// desktop's skip check is `/-fast$/i`; an exact-case sibling lookup
    /// would silently DROP a differently-cased fast variant).
    static func collapseModelFamilies(_ models: [String]) -> [ModelFamily] {
        // Case-insensitive index → the actually-cased id (first occurrence wins).
        let byLower = Dictionary(models.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var families: [ModelFamily] = []
        var consumed = Set<String>()

        for model in models {
            if consumed.contains(model) { continue }

            if let base = fastBase(of: model), byLower[base.lowercased()] != nil {
                // Represented by its base entry — the base attaches it as fastId.
                continue
            }

            let fastId = byLower[model.lowercased() + "-fast"]
            families.append(ModelFamily(id: model, fastId: fastId))
            consumed.insert(model)
            if let fastId { consumed.insert(fastId) }
        }
        return families
    }

    /// The base model id if `model` is a `…-fast` variant (case-insensitive
    /// suffix, like the desktop's `/-fast$/i`), else nil.
    static func fastBase(of model: String) -> String? {
        guard model.count > 5, model.lowercased().hasSuffix("-fast") else { return nil }
        return String(model.dropLast(5))
    }

    // MARK: Defaults / effective set

    /// The default-visible key set: the curated top-N families per provider.
    static func defaultVisibleKeys(providers: [ModelProvider]) -> Set<String> {
        var keys = Set<String>()
        for provider in providers {
            for family in collapseModelFamilies(provider.models).prefix(defaultVisiblePerProvider) {
                keys.insert(key(provider: provider.slug, model: family.id))
            }
        }
        return keys
    }

    /// Resolve which keys are currently visible: the user's explicit set when
    /// configured, otherwise the curated default for the given providers.
    static func effectiveVisibleKeys(stored: Set<String>?, providers: [ModelProvider]) -> Set<String> {
        stored ?? defaultVisibleKeys(providers: providers)
    }

    // MARK: Persistence

    /// Explicit visible set, or nil when the user hasn't customized.
    static func load(defaults: UserDefaults = .standard) -> Set<String>? {
        guard let raw = defaults.string(forKey: defaultsKey),
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(arr)
    }

    /// Persist an explicit visible set; pass nil to clear the customization
    /// (reverting to the curated default).
    static func save(_ keys: Set<String>?, defaults: UserDefaults = .standard) {
        guard let keys else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(Array(keys).sorted()),
           let raw = String(data: data, encoding: .utf8) {
            defaults.set(raw, forKey: defaultsKey)
        }
    }

    // MARK: Current-selection identity (the dual-select fix)

    /// The family id that should highlight as CURRENT in `provider`'s section,
    /// or nil when the current model isn't this provider's. Provider-aware by
    /// construction — the same model name under a different provider does NOT
    /// match (mirrors desktop `model-menu-panel` selection: provider first,
    /// then family base/fast id).
    static func currentFamilyId(
        providerSlug: String,
        currentProvider: String,
        currentModel: String,
        families: [ModelFamily]
    ) -> String? {
        guard !currentModel.isEmpty, providerSlug == currentProvider else { return nil }
        return families.first { $0.id == currentModel || $0.fastId == currentModel }?.id
    }
}
