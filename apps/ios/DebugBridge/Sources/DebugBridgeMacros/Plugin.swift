// DebugBridgeMacros — compiler plugin backing the @Snapshotable marker.
//
// Installed for task UI-G per the ios-qa skill. The plugin host is built for
// the build machine (macOS) and applied during the iOS app's DEBUG compile.
// `SnapshotableMacro` is a peer macro that produces zero peer declarations:
// it is purely a marker the gen-accessors tool keys on. This whole target is
// only pulled into the build graph through DebugBridgeCore, which the app
// depends on with `.when(configuration: .debug)`, so Release builds never
// invoke the plugin.

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftCompilerPlugin

public struct SnapshotableMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Marker only — emits no peer declarations.
        []
    }
}

@main
struct DebugBridgePlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [SnapshotableMacro.self]
}
