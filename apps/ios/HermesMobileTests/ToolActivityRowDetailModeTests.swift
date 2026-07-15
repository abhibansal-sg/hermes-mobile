import XCTest
@testable import HermesMobile

/// STR-464: coverage for the global product/technical toggle gating a tool
/// row's expanded detail panel. `ToolActivityRow.detailContent(for:technicalDetailEnabled:)`
/// is the pure decision the view switches on, so these tests exercise it
/// directly rather than SwiftUI view introspection.
final class ToolActivityRowDetailModeTests: XCTestCase {

    // MARK: - Absent defaults -> product

    func testAbsentDefaultsKeyReadsAsProductMode() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "ToolActivityRowDetailModeTests"))
        suite.removePersistentDomain(forName: "ToolActivityRowDetailModeTests")
        defer { suite.removePersistentDomain(forName: "ToolActivityRowDetailModeTests") }

        // No write yet — `DefaultsKeys.toolTechnicalDetailValue` (the same
        // read `@AppStorage(DefaultsKeys.toolTechnicalDetail)` performs) must
        // read the absent key as product (false), matching the contract's
        // "default absent key = product summary mode".
        XCTAssertFalse(DefaultsKeys.toolTechnicalDetailValue(suite))
    }

    func testToggledDefaultsKeyReadsAsTechnicalMode() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "ToolActivityRowDetailModeTests"))
        suite.removePersistentDomain(forName: "ToolActivityRowDetailModeTests")
        defer { suite.removePersistentDomain(forName: "ToolActivityRowDetailModeTests") }

        suite.set(true, forKey: DefaultsKeys.toolTechnicalDetail)
        XCTAssertTrue(DefaultsKeys.toolTechnicalDetailValue(suite))
    }

    // MARK: - Product mode chooses summary over raw preview

    func testProductModeUsesSummaryLineNotRawResultPreview() {
        let activity = ToolActivity(
            id: "tool-1", name: "web_search",
            argsSummary: "{\"query\": \"rust async runtime\"}",
            progressText: "",
            resultPreview: "{\"raw\": \"should not appear in product mode\"}",
            state: .done, durationMs: nil, todos: nil,
            resultSummary: "Found 12 results for \"rust async runtime\""
        )

        let content = ToolActivityRow.detailContent(for: activity, technicalDetailEnabled: false)
        guard case .summary(let text) = content else {
            return XCTFail("Product mode must resolve to .summary, got \(content)")
        }
        XCTAssertEqual(text, "Found 12 results for \"rust async runtime\"")
        XCTAssertFalse(text.contains("should not appear in product mode"),
                        "Product mode must never surface the raw result JSON")
    }

    func testProductModeFallsBackToCalmStateLineWithoutInventingSuccess() {
        // No `resultSummary` and no `durationMs` — the calm fallback must be
        // the existing "Done"/"Failed" state line, never a fabricated success
        // message, and never the raw (empty here) result preview.
        let done = ToolActivity(
            id: "tool-1", name: "mystery_tool", argsSummary: "",
            progressText: "", resultPreview: "",
            state: .done, durationMs: nil, todos: nil
        )
        guard case .summary(let doneText) = ToolActivityRow.detailContent(for: done, technicalDetailEnabled: false) else {
            return XCTFail("Expected .summary for product mode")
        }
        XCTAssertEqual(doneText, "Done")

        let failed = ToolActivity(
            id: "tool-2", name: "mystery_tool", argsSummary: "",
            progressText: "", resultPreview: "",
            state: .failed, durationMs: nil, todos: nil
        )
        guard case .summary(let failedText) = ToolActivityRow.detailContent(for: failed, technicalDetailEnabled: false) else {
            return XCTFail("Expected .summary for product mode")
        }
        XCTAssertEqual(failedText, "Failed")
    }

    // MARK: - Technical mode includes raw result/args

    func testTechnicalModeIncludesRawArgumentsAndResultPreview() {
        let activity = ToolActivity(
            id: "tool-1", name: "execute_code",
            argsSummary: "{\"code\": \"print('hi')\"}",
            progressText: "",
            resultPreview: "{\"stdout\": \"hi\\n\"}",
            state: .done, durationMs: nil, todos: nil,
            resultSummary: "Ran successfully"
        )

        let content = ToolActivityRow.detailContent(for: activity, technicalDetailEnabled: true)
        guard case .raw(let argumentsSummary, let resultPreview) = content else {
            return XCTFail("Technical mode must resolve to .raw, got \(content)")
        }
        XCTAssertEqual(argumentsSummary, "{\"code\": \"print('hi')\"}")
        XCTAssertEqual(resultPreview, "{\"stdout\": \"hi\\n\"}")
    }

    // MARK: - Source-wiring: DefaultsKeys.toolTechnicalDetail has a real read site

    func testToolActivityRowReadsGlobalTechnicalDetailPreference() throws {
        let source = try Self.toolActivityRowSource()

        XCTAssertTrue(source.contains("@AppStorage(DefaultsKeys.toolTechnicalDetail)"),
                       "ToolActivityRow must read the global toggle via @AppStorage")
        XCTAssertTrue(source.contains("Self.detailContent(for: activity, technicalDetailEnabled: technicalDetailEnabled)"),
                       "The expanded panel must gate its content on the persisted preference")
    }

    // MARK: - Source-wiring: a visible control on the tool-row surface writes the preference

    /// The spec requires a *visible* Product/Technical control on the tool-row
    /// surface itself (not just a Settings-screen entry) — expanding a row is
    /// the moment the preference matters. SwiftUI view introspection can't
    /// assert "is on screen" from XCTest, so this proves the control exists
    /// as a real, identifiable, tappable element that writes
    /// `technicalDetailEnabled` (the same `@AppStorage` binding the read site
    /// above uses) rather than merely reading it.
    func testToolActivityRowSurfaceHasAWritableModeToggle() throws {
        let source = try Self.toolActivityRowSource()

        XCTAssertTrue(source.contains("accessibilityIdentifier(\"toolDetailModeToggle\")"),
                       "The tool-row surface must expose an identifiable Product/Technical control")
        XCTAssertTrue(source.contains("technicalDetailEnabled.toggle()"),
                       "The control must write the persisted preference, not just read it")
        XCTAssertTrue(source.contains("detailModeToggle") && source.contains("private var detailActions"),
                       "The toggle must be wired into the row's always-visible detail actions, not orphaned")
    }

    private static func toolActivityRowSource() throws -> String {
        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Views/Chat/ToolActivityRow.swift")
        return try String(contentsOf: sourcePath, encoding: .utf8)
    }
}
