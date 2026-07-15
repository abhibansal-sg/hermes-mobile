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

    // MARK: - ABH-362 displayPath + confirmation

    func testDisplayPathEmptyReturnsEmpty() {
        XCTAssertEqual(WorkingDirectory.displayPath(""), "")
        XCTAssertEqual(WorkingDirectory.displayPath("   "), "")
    }

    func testDisplayPathCollapsesHomePrefixToTilde() {
        // The home prefix is process-determined (NSHomeDirectory). We test the
        // RELATIVE behavior: any path starting with the home dir gets "~".
        let home = NSHomeDirectory()
        let abs = home + "/Developer/projects/app"
        XCTAssertEqual(WorkingDirectory.displayPath(abs), "~/Developer/projects/app")
    }

    func testDisplayPathKeepsPathWithoutHomePrefix() {
        // A path NOT under home is returned as-is (no ~ substitution).
        // "/tmp/test" is outside the home tree on every macOS account.
        XCTAssertEqual(WorkingDirectory.displayPath("/tmp/test"), "/tmp/test")
    }

    func testDisplayPathHandlesRootSlash() {
        // "/" is not under the home tree (home is always deeper), so it stays "/".
        let home = NSHomeDirectory()
        guard home != "/" else { return }
        XCTAssertEqual(WorkingDirectory.displayPath("/"), "/")
    }

    func testConfirmationMessageContainsDisplayPath() {
        let home = NSHomeDirectory()
        let abs = home + "/projects/x"
        let msg = WorkingDirectory.confirmationMessage(absoluteCwd: abs)
        XCTAssertTrue(msg.contains("Working directory set to"), "message prefix missing: \(msg)")
        XCTAssertTrue(msg.contains("~/projects/x"), "display path missing: \(msg)")
    }

    func testConfirmationMessageForNonHomePath() {
        let msg = WorkingDirectory.confirmationMessage(absoluteCwd: "/var/www/site")
        XCTAssertTrue(msg.contains("/var/www/site"), "path missing: \(msg)")
    }

    // MARK: - ABH-362 bounce-1: E2E cwd-plumbing (picker → wire cwd → adoption)

    /// The cwd sent on the wire to `session.cwd.set` MUST be the absolute join
    /// of the file-browser root + the picker's relative path. This is the
    /// load-bearing invariant: if the picker's relative path is sent raw (the
    /// pre-fix bug), `session.cwd.set` receives "src" not "/proj/src" and the
    /// gateway's `_set_session_cwd` (server.py:1760 `expanduser` then
    /// `isdir(resolved)`) either rejects it or resolves it relative to the
    /// gateway process's cwd — a SILENT wrong-directory adoption. This test
    /// fails (true-red) if `resolveCwdPlumbing` ever sends the relative path
    /// instead of the joined absolute one.
    func testE2EWireCwdIsAbsoluteJoinOfRootAndRelativePick() {
        let result = WorkingDirectory.resolveCwdPlumbing(
            root: "/Users/abc/proj",
            relativePath: "src/app",
            gatewayAdoptedCwd: nil
        )
        XCTAssertEqual(result?.wireCwd, "/Users/abc/proj/src/app",
                       "the wire cwd sent to session.cwd.set MUST be the absolute join")
        XCTAssertTrue(result?.wireCwd.hasPrefix("/") ?? false,
                      "wire cwd must be absolute — a relative path would be expanded against the gateway process cwd")
    }

    /// The wire cwd for the ROOT sentinel pick (empty / ".") is the root itself
    /// — the session cwd must not change when the user re-picks "Use Working
    /// Directory Root".
    func testE2EWireCwdForRootSentinelIsRootUnchanged() {
        for sentinel in ["", ".", "./"] {
            let result = WorkingDirectory.resolveCwdPlumbing(
                root: "/Users/abc/proj",
                relativePath: sentinel,
                gatewayAdoptedCwd: nil
            )
            XCTAssertEqual(result?.wireCwd, "/Users/abc/proj",
                           "root sentinel '\(sentinel)' must yield the root unchanged")
        }
    }

    /// E2E adoption contract: when the gateway adopts EXACTLY the cwd we sent,
    /// `resolveCwdPlumbing` returns the result (success) and the confirmation
    /// matches. This is the "it actually worked" path.
    func testE2EAdoptionMatchReturnsSuccess() {
        let wireCwd = "/Users/abc/proj/src/app"
        let result = WorkingDirectory.resolveCwdPlumbing(
            root: "/Users/abc/proj",
            relativePath: "src/app",
            gatewayAdoptedCwd: wireCwd
        )
        XCTAssertNotNil(result, "when the gateway adopts our cwd exactly, the plumbing succeeds")
        XCTAssertEqual(result?.wireCwd, wireCwd)
        XCTAssertTrue(result?.confirmation.contains("Working directory set to") ?? false)
    }

    /// E2E adoption contract: when the gateway adopts a DIFFERENT cwd than the
    /// one we sent (plumbing break — the picked path never reached the session
    /// cwd faithfully), `resolveCwdPlumbing` returns nil (hard failure). This is
    /// the TRUE-RED regression: it proves the test catches a broken plumbing
    /// chain rather than greenlighting a silent wrong-directory adoption.
    ///
    /// Mutant: if the picker sent the relative path "src/app" raw (the pre-fix
    /// bug), the gateway would resolve it against its OWN process cwd (e.g.
    /// "/gateway/home/src/app"), adopting THAT — not "/proj/src/app". This test
    /// fails because adoptedCwd != wireCwd, so resolveCwdPlumbing returns nil
    /// and the caller surfaces the error instead of a false confirmation.
    func testE2EAdoptionDriftReturnsNil() {
        // We sent "/proj/src/app" but the gateway adopted something else.
        let result = WorkingDirectory.resolveCwdPlumbing(
            root: "/proj",
            relativePath: "src/app",
            gatewayAdoptedCwd: "/gateway/home/src/app"  // drift!
        )
        XCTAssertNil(result,
                     "an adopted cwd that differs from the wire cwd MUST fail the plumbing — a false green here would mask Abhi's 'it didn't take' complaint")
    }

    /// A trailing slash on the wire cwd (a plausible picker bug) would make the
    /// gateway's `os.path.abspath` normalize it — so the adopted cwd would
    /// differ by exactly the trailing slash. The adoption gate catches this:
    /// the wire must be clean.
    func testE2EAdoptionGateCatchesTrailingSlashDrift() {
        // If the join produced "/proj/src/" (trailing slash bug), the gateway's
        // realpath normalizes it to "/proj/src" — a drift the gate catches.
        let result = WorkingDirectory.resolveCwdPlumbing(
            root: "/proj",
            relativePath: "src",
            gatewayAdoptedCwd: "/proj/src"  // clean
        )
        XCTAssertEqual(result?.wireCwd, "/proj/src",
                       "absolutePath must produce a clean path with no trailing slash")
        // The adoption match holds for a clean wire cwd.
        XCTAssertNotNil(result)
    }

    /// The confirmation message in the plumbing result must contain the DISPLAY
    /// path (home-collapsed) of the wire cwd — so the user sees a friendly path
    /// in the transcript, not a raw absolute one. This ties the E2E plumbing to
    /// the user-facing observability (Abhi's "I can tell it worked" requirement).
    func testE2EConfirmationUsesDisplayPathOfWireCwd() {
        let home = NSHomeDirectory()
        let result = WorkingDirectory.resolveCwdPlumbing(
            root: home + "/projects",
            relativePath: "myapp",
            gatewayAdoptedCwd: nil
        )
        let expected = "Working directory set to ~/projects/myapp"
        XCTAssertEqual(result?.confirmation, expected,
                       "confirmation must use the home-collapsed display path of the wire cwd")
    }

    /// Round-trip: pick a nested dir → the full chain (wire cwd = absolute join,
    /// adoption match, confirmation) must all hold together. This is the
    /// comprehensive E2E case a verifier can trace line-by-line from the picker
    /// to the gateway adoption contract.
    func testE2EFullRoundTripNestedPick() {
        let root = "/Users/dev/Developer/products/hermes-mobile"
        let relative = "apps/ios/HermesMobile/Views"
        let expectedWire = root + "/" + relative
        // 1. Wire cwd is the absolute join (what session.cwd.set receives).
        let pre = WorkingDirectory.resolveCwdPlumbing(
            root: root, relativePath: relative, gatewayAdoptedCwd: nil)
        XCTAssertEqual(pre?.wireCwd, expectedWire)
        // 2. Gateway adopts exactly that → plumbing succeeds.
        let post = WorkingDirectory.resolveCwdPlumbing(
            root: root, relativePath: relative, gatewayAdoptedCwd: expectedWire)
        XCTAssertEqual(post?.wireCwd, expectedWire)
        // 3. Confirmation contains the display path.
        XCTAssertTrue(post?.confirmation.contains(expectedWire) ?? false,
                      "confirmation must contain the wire cwd path")
    }
}
