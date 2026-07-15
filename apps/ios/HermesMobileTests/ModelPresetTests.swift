import XCTest
@testable import HermesMobile

/// ABH-383: per-model preset persistence + apply-on-select + default fallback.
///
/// Covers the three guarantees of the ModelPresetStore contract:
///   1. PERSIST — writing a preset survives a store reload (UserDefaults round-trip).
///   2. APPLY-ON-SELECT — a stored preset is read back intact for its model.
///   3. DEFAULT FALLBACK — a model with no stored preset returns `.empty`
///      (no effort, no fast) so the gateway default is left untouched.
///
/// The apply-on-select wiring inside SessionModelPopover (the UI path that
/// calls `presetStore.preset(...)` after a model switch) is an async MainActor
/// view method and is covered by the ios-sim CUJ smoke (CUJ-35). This class
/// pins the PERSISTENCE LAYER the wiring depends on — if these tests pass,
/// the store reliably remembers + returns what the wiring reads.
final class ModelPresetTests: XCTestCase {

    /// Isolated UserDefaults suite so tests never touch `UserDefaults.standard`.
    private func makeDefaults() -> UserDefaults {
        let suite = "ModelPresetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Default fallback

    func testNoPresetReturnsEmpty() {
        let store = ModelPresetStore(defaults: makeDefaults())
        let preset = store.preset(forProvider: "anthropic", model: "claude-opus-4")
        XCTAssertEqual(preset, .empty)
        XCTAssertNil(preset.effort)
        XCTAssertNil(preset.fast)
    }

    func testEmptyPresetIsTheNilSentinel() {
        // `.empty` has both fields nil — the gateway default should be kept.
        let empty = ModelPreset.empty
        XCTAssertNil(empty.effort)
        XCTAssertNil(empty.fast)
    }

    // MARK: - Persist (round-trip)

    func testEffortOnlyPresetPersists() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)
        store.set(provider: "anthropic", model: "claude-opus-4",
                  preset: ModelPreset(effort: "high", fast: nil))
        // Re-create the store to prove it reads from UserDefaults, not memory.
        let store2 = ModelPresetStore(defaults: defaults)
        let read = store2.preset(forProvider: "anthropic", model: "claude-opus-4")
        XCTAssertEqual(read.effort, "high")
        XCTAssertNil(read.fast)
    }

    func testFastOnlyPresetPersists() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)
        store.set(provider: "openai", model: "gpt-5.5",
                  preset: ModelPreset(effort: nil, fast: true))
        let store2 = ModelPresetStore(defaults: defaults)
        let read = store2.preset(forProvider: "openai", model: "gpt-5.5")
        XCTAssertNil(read.effort)
        XCTAssertEqual(read.fast, true)
    }

    func testBothDimensionsPresetPersists() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)
        store.set(provider: "zai", model: "glm-5.2",
                  preset: ModelPreset(effort: "xhigh", fast: false))
        let store2 = ModelPresetStore(defaults: defaults)
        let read = store2.preset(forProvider: "zai", model: "glm-5.2")
        XCTAssertEqual(read.effort, "xhigh")
        XCTAssertEqual(read.fast, false)
    }

    // MARK: - Key isolation (different models, same provider)

    func testDifferentModelsAreIndependent() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)
        store.set(provider: "anthropic", model: "claude-opus-4",
                  preset: ModelPreset(effort: "high", fast: nil))
        store.set(provider: "anthropic", model: "claude-sonnet-4",
                  preset: ModelPreset(effort: "minimal", fast: true))
        let opus = store.preset(forProvider: "anthropic", model: "claude-opus-4")
        let sonnet = store.preset(forProvider: "anthropic", model: "claude-sonnet-4")
        XCTAssertEqual(opus.effort, "high")
        XCTAssertNil(opus.fast)
        XCTAssertEqual(sonnet.effort, "minimal")
        XCTAssertEqual(sonnet.fast, true)
    }

    // MARK: - Key isolation (same model, different providers)

    func testDifferentProvidersAreIndependent() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)
        store.set(provider: "openai", model: "gpt-5.5",
                  preset: ModelPreset(effort: "high", fast: true))
        // Same model id on a different provider — must NOT collide.
        let other = store.preset(forProvider: "azure", model: "gpt-5.5")
        XCTAssertEqual(other, .empty)
    }

    // MARK: - Merge semantics

    func testMergePreservesUnsetDimension() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)
        store.set(provider: "anthropic", model: "claude-opus-4",
                  preset: ModelPreset(effort: "high", fast: nil))
        // Merge a fast preference — the existing effort must survive.
        store.merge(provider: "anthropic", model: "claude-opus-4",
                    patch: ModelPreset(effort: nil, fast: true))
        let read = store.preset(forProvider: "anthropic", model: "claude-opus-4")
        XCTAssertEqual(read.effort, "high")  // preserved
        XCTAssertEqual(read.fast, true)      // merged in
    }

    func testMergeOverwritesSetDimension() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)
        store.set(provider: "anthropic", model: "claude-opus-4",
                  preset: ModelPreset(effort: "high", fast: nil))
        store.merge(provider: "anthropic", model: "claude-opus-4",
                    patch: ModelPreset(effort: "low", fast: nil))
        let read = store.preset(forProvider: "anthropic", model: "claude-opus-4")
        XCTAssertEqual(read.effort, "low")   // overwritten
    }

    // MARK: - Clear semantics

    func testClearRemovesPreset() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)
        store.set(provider: "anthropic", model: "claude-opus-4",
                  preset: ModelPreset(effort: "high", fast: true))
        store.clear(provider: "anthropic", model: "claude-opus-4")
        let read = store.preset(forProvider: "anthropic", model: "claude-opus-4")
        XCTAssertEqual(read, .empty)
    }

    func testSetEmptyRemovesPreset() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)
        store.set(provider: "anthropic", model: "claude-opus-4",
                  preset: ModelPreset(effort: "high", fast: true))
        store.set(provider: "anthropic", model: "claude-opus-4", preset: .empty)
        let read = store.preset(forProvider: "anthropic", model: "claude-opus-4")
        XCTAssertEqual(read, .empty)
    }

    // MARK: - Key format

    func testKeyFormatMatchesVisibilityKey() {
        // The preset key MUST match the visibility-store format so a single
        // identity scheme spans the picker (provider::model).
        XCTAssertEqual(
            ModelPresetStore.key(provider: "anthropic", model: "claude-opus-4"),
            "anthropic::claude-opus-4"
        )
        XCTAssertEqual(
            ModelPresetStore.key(provider: "anthropic", model: "claude-opus-4"),
            ModelVisibility.key(provider: "anthropic", model: "claude-opus-4")
        )
    }

    // MARK: - Apply-on-select simulation (the CUJ-35 journey in logic)

    /// Simulates the CUJ journey: pick model A → set high effort → pick model B
    /// → return to model A → effort is restored. This exercises the store's
    /// read-after-write round-trip that the UI wiring depends on.
    func testApplyOnSelectRestoresPreviousPreset() {
        let defaults = makeDefaults()
        let store = ModelPresetStore(defaults: defaults)

        // Step 1: pick model A (claude-opus-4), set high effort.
        store.merge(provider: "anthropic", model: "claude-opus-4",
                    patch: ModelPreset(effort: "high", fast: nil))

        // Step 2: pick model B (gpt-5.5) — no preset yet.
        let presetB = store.preset(forProvider: "openai", model: "gpt-5.5")
        XCTAssertEqual(presetB, .empty)  // default fallback

        // Step 3: return to model A.
        let presetA = store.preset(forProvider: "anthropic", model: "claude-opus-4")
        XCTAssertEqual(presetA.effort, "high")  // restored!
        XCTAssertNil(presetA.fast)
    }
}
