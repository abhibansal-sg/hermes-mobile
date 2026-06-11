// swift-tools-version:5.9
//
// DebugBridge — gstack iOS debug bridge (task UI-G). Installed per the
// ios-qa / ios-sync skills. Three Debug-config-only library products:
//
//   - DebugBridgeCore   Swift, cross-platform (Foundation + Network).
//                       Hosts the StateServer, DebugBridgeManager, the
//                       @Snapshotable marker, the AppState protocol, and the
//                       bridge-resolver seams (Elements/Screenshot/Mutation).
//   - DebugBridgeTouch  Objective-C, iOS-only. KIF-derived in-process touch
//                       synthesis (UITouch + IOHIDEvent + iOS 18
//                       _UIHitTestContext for SwiftUI Buttons).
//   - DebugBridgeUI     Swift, iOS-only. ScreenshotBridge / ElementsBridge /
//                       MutationBridge implementations + DebugOverlay. Depends
//                       on Core + Touch.
//
// The structural Release-build guard is `.when(configuration: .debug)` on the
// consuming target's dependency (declared in apps/ios/project.yml). Every
// source file is additionally wrapped in `#if DEBUG`, so a Release build links
// and compiles to nothing. See the ios-clean skill for full removal steps.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "DebugBridge",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DebugBridgeCore", targets: ["DebugBridgeCore"]),
        .library(name: "DebugBridgeUI", targets: ["DebugBridgeUI"]),
        .library(name: "DebugBridgeTouch", targets: ["DebugBridgeTouch"]),
    ],
    dependencies: [
        // Backs the @Snapshotable marker macro. Only the macro plugin host is
        // built from this; it runs on the build machine, not the device.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "509.0.0"..<"603.0.0"),
    ],
    targets: [
        .macro(
            name: "DebugBridgeMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/DebugBridgeMacros"
        ),
        .target(
            name: "DebugBridgeCore",
            dependencies: ["DebugBridgeMacros"],
            path: "Sources/DebugBridgeCore",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "DebugBridgeTouch",
            dependencies: [],
            path: "Sources/DebugBridgeTouch",
            publicHeadersPath: "include",
            linkerSettings: [
                // IOKit is loaded dynamically via dlopen at runtime (it's a
                // private framework on iOS and can't be linked statically).
                // UIKit links normally.
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "DebugBridgeUI",
            dependencies: ["DebugBridgeCore", "DebugBridgeTouch"],
            path: "Sources/DebugBridgeUI",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "DebugBridgeCoreTests",
            dependencies: ["DebugBridgeCore"],
            path: "Tests/DebugBridgeCoreTests"
        ),
    ]
)
