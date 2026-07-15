// Snapshotable — marker attribute for snapshot-eligible @Observable fields.
//
// Installed for task UI-G per the ios-qa / ios-sync skills. Applying
// `@Snapshotable` to a stored property of an `@Observable` class tells the
// gen-accessors tool (DebugBridge/Tools/gen-accessors) to emit a typed
// StateServer read accessor for that field. The macro itself is a no-op
// peer macro: it expands to zero declarations, so it adds no runtime cost and
// does not perturb the `@Observable` macro's `@ObservationTracked` rewrite of
// the same property (a property wrapper would — verified during install).
//
// This marker lives inside DebugBridgeCore on purpose: removing the SPM
// dependency (the ios-clean procedure) removes the macro declaration too, so
// any leftover `@Snapshotable` annotation in app code fails to resolve and is
// surfaced loudly rather than silently shipping. The whole declaration is
// #if DEBUG-gated, so it does not exist in Release.

#if DEBUG

/// Marks a stored property of an `@Observable` class as snapshot-eligible for
/// the gstack debug bridge. Expands to nothing; it exists only as a textual
/// marker the codegen tool reads via swift-syntax.
@attached(peer)
public macro Snapshotable() = #externalMacro(module: "DebugBridgeMacros", type: "SnapshotableMacro")

#endif // DEBUG
