import XCTest
@testable import HermesMobile

/// Pure-logic coverage for the working-directory picker → `session.cwd.set`
/// round-trip (F4A-A2 wiring of A1's ``WorkingDirPicker``):
///   - ``WorkingDirectory/absolutePath(root:relative:)`` relative→absolute join,
///     including the edge cases the contract calls out (".", nested, root itself).
///   - ``WorkingDirectory/mapSetError(_:)`` gateway code → native error mapping
///     for the pinned `session.cwd.set` codes (4009 / 4016 / 4017).
final class WorkingDirectoryTests: XCTestCase {

    // MARK: - relative → absolute join

    func testRootSentinelEmptyReturnsRootUnchanged() {
        // "Use Working Directory Root" hands back "" — the cwd stays the root.
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/Users/abc/proj", relative: ""),
            "/Users/abc/proj"
        )
    }

    func testRootSentinelDotReturnsRoot() {
        // A bare "." (or "./") is also the root sentinel.
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/Users/abc/proj", relative: "."),
            "/Users/abc/proj"
        )
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/Users/abc/proj", relative: "./"),
            "/Users/abc/proj"
        )
    }

    func testSingleLevelJoin() {
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/Users/abc/proj", relative: "src"),
            "/Users/abc/proj/src"
        )
    }

    func testNestedJoin() {
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/Users/abc/proj", relative: "src/app/views"),
            "/Users/abc/proj/src/app/views"
        )
    }

    func testRootWithTrailingSlashNormalized() {
        // The root's own trailing slash must not produce "proj//src".
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/Users/abc/proj/", relative: "src"),
            "/Users/abc/proj/src"
        )
    }

    func testRelativeLeadingDotSlashStripped() {
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/r", relative: "./src/lib"),
            "/r/src/lib"
        )
    }

    func testRelativeCollapsesRedundantAndTrailingSeparators() {
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/r", relative: "a//b/"),
            "/r/a/b"
        )
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/r", relative: "a/./b"),
            "/r/a/b"
        )
    }

    func testFilesystemRootAsRoot() {
        // The filesystem root "/" is the degenerate base: join must not double the
        // separator.
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/", relative: "etc"),
            "/etc"
        )
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "/", relative: ""),
            "/"
        )
    }

    func testWhitespaceTrimmedFromBoth() {
        XCTAssertEqual(
            WorkingDirectory.absolutePath(root: "  /r  ", relative: "  src  "),
            "/r/src"
        )
    }

    func testNormalizedRelativeRootSentinels() {
        XCTAssertEqual(WorkingDirectory.normalizedRelative(""), "")
        XCTAssertEqual(WorkingDirectory.normalizedRelative("."), "")
        XCTAssertEqual(WorkingDirectory.normalizedRelative("./"), "")
        XCTAssertEqual(WorkingDirectory.normalizedRelative("a/b"), "a/b")
        XCTAssertEqual(WorkingDirectory.normalizedRelative("./a//b/"), "a/b")
    }

    // MARK: - session.cwd.set error mapping

    func testMapSessionBusy4009() {
        let error = GatewayError.rpc(code: 4009, message: "session busy")
        XCTAssertEqual(WorkingDirectory.mapSetError(error), .sessionBusy)
    }

    func testMapEmptyCwd4016() {
        let error = GatewayError.rpc(code: 4016, message: "cwd required")
        XCTAssertEqual(WorkingDirectory.mapSetError(error), .empty)
    }

    func testMapMissingDirectory4017CarriesServerMessage() {
        let error = GatewayError.rpc(code: 4017, message: "working directory does not exist")
        XCTAssertEqual(
            WorkingDirectory.mapSetError(error),
            .missingDirectory("working directory does not exist")
        )
    }

    func testMapUnknownRpcCodeFoldsToOther() {
        let error = GatewayError.rpc(code: 4099, message: "weird failure")
        XCTAssertEqual(WorkingDirectory.mapSetError(error), .other("weird failure"))
    }

    func testMapNonRpcErrorFoldsToOther() {
        let error = GatewayError.notConnected
        guard case .other(let message) = WorkingDirectory.mapSetError(error) else {
            return XCTFail("expected .other for a non-RPC error")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - SetError messages

    func testBusyMessageIsActionable() {
        XCTAssertTrue(WorkingDirectory.SetError.sessionBusy.message.lowercased().contains("busy"))
    }

    func testMissingDirectoryFallsBackWhenServerMessageEmpty() {
        XCTAssertFalse(WorkingDirectory.SetError.missingDirectory("").message.isEmpty)
    }

    func testOtherFallsBackWhenDetailEmpty() {
        XCTAssertFalse(WorkingDirectory.SetError.other("").message.isEmpty)
    }
}
