import Foundation

// MARK: - Per-model presets (ABH-383)
//
// Remembers each model's reasoning-effort + fast-mode preference, keyed by
// `provider::model` (the same stable identity the visibility store uses).
// On model switch the stored preset for the newly-selected model is re-applied
// to the session automatically; when the user changes effort/fast the new
// value is persisted for that model so it sticks on the next switch back.
//
// Mirrors the desktop reference `apps/desktop/src/store/model-presets.ts`
// (ModelPreset { effort?, fast? }, modelPresetKey, load, get, set, applyModelPreset).
//
// UNSET dimensions fall back to the gateway default (no `config.set` write):
// if a model has no stored preset, or a preset that only carries `effort`, the
// fast dimension is simply not touched — the gateway keeps whatever the
// session already has. This matches the desktop's `applyModelPreset` contract:
// `undefined` skips that dimension so the picker does not rewrite
// `agent.*` defaults on every selection.

/// One model's remembered reasoning-effort + fast-mode preference.
/// Optional fields — `nil` means "no preference, use the gateway default".
struct ModelPreset: Equatable, Sendable, Codable {
    /// Reasoning effort: "minimal", "low", "medium", "high", "xhigh", or
    /// "none"/nil (no preference). Empty string is normalized to nil on store.
    var effort: String?
    /// Fast-mode preference. `nil` = no preference (do not touch on apply).
    var fast: Bool?

    /// An empty preset (no dimensions set) — the "no preference" sentinel.
    static let empty = ModelPreset()
}

/// UserDefaults-backed store of per-`provider::model` presets.
///
/// Pure persistence layer: it does NOT own the apply path (that lives in the
/// picker / `ConnectionStore`, which own the session id and WS client). This
/// type only reads/writes the on-disk dictionary so it can be unit-tested in
/// isolation (inject a defaults instance) without a live session or gateway.
///
/// Not `@MainActor` — `UserDefaults` is thread-safe, and keeping the store
/// nonisolated lets the test suite exercise it without actor hops. The UI
/// caller (`SessionModelPopover`) is already `@MainActor` so calls from there
/// are safe.
final class ModelPresetStore: @unchecked Sendable {
    /// The UserDefaults domain the presets live in. Overridable for tests.
    private let defaults: UserDefaults

    /// Storage key (matches the desktop constant `hermes.desktop.model-presets`).
    static let storageKey = "hermes.mobile.model-presets"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Key

    /// Stable `provider::model` key (matches `ModelVisibility.key` format).
    static func key(provider: String, model: String) -> String {
        "\(provider)::\(model)"
    }

    // MARK: - Read

    /// The preset for one model, or `.empty` if none is stored.
    func preset(forProvider provider: String, model: String) -> ModelPreset {
        let all = loadAll()
        return all[Self.key(provider: provider, model: model)] ?? .empty
    }

    /// The entire persisted preset map (used by tests + diagnostics).
    func loadAll() -> [String: ModelPreset] {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return [:]
        }
        let decoded = try? JSONDecoder().decode([String: ModelPreset].self, from: data)
        return decoded ?? [:]
    }

    // MARK: - Write

    /// Merge a partial preset for one model and persist. Existing dimensions
    /// for the same model are preserved unless overwritten by `patch`.
    func merge(provider: String, model: String, patch: ModelPreset) {
        var all = loadAll()
        let k = Self.key(provider: provider, model: model)
        var current = all[k] ?? .empty
        // Normalize: empty-string effort → nil (means "no preference").
        if let e = patch.effort, !e.isEmpty {
            current.effort = e
        } else if patch.effort != nil {
            current.effort = nil
        }
        if patch.fast != nil {
            current.fast = patch.fast
        }
        // Drop the entry entirely if it's empty so we don't accumulate
        // no-op rows.
        if current == .empty {
            all.removeValue(forKey: k)
        } else {
            all[k] = current
        }
        save(all)
    }

    /// Replace the preset for one model wholesale (used by tests).
    func set(provider: String, model: String, preset: ModelPreset) {
        var all = loadAll()
        let k = Self.key(provider: provider, model: model)
        if preset == .empty {
            all.removeValue(forKey: k)
        } else {
            all[k] = preset
        }
        save(all)
    }

    /// Remove the stored preset for one model (revert to gateway default).
    func clear(provider: String, model: String) {
        var all = loadAll()
        all.removeValue(forKey: Self.key(provider: provider, model: model))
        save(all)
    }

    /// Wipe all presets (test helper).
    func clearAll() {
        save([:])
    }

    // MARK: - Persistence

    private func save(_ map: [String: ModelPreset]) {
        if map.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
