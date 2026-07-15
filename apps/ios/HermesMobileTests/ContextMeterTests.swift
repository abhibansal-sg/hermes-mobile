import XCTest
@testable import HermesMobile

/// Coverage for the H1 context-window meter: `UsageStats` context-field decode
/// (snake_case → camelCase, the fields the app used to drop), the `formatK`
/// terse-token formatter, the model-picker stats line, the chip's threshold /
/// suffix logic, and the per-turn usage footer's "ctx N" clause.
final class ContextMeterTests: XCTestCase {

    // MARK: - UsageStats context-field decode

    func testUsageStatsDecodesContextFieldsSnakeCase() throws {
        let value: JSONValue = [
            "input": 1000,
            "output": 200,
            "total": 1200,
            "context_used": 142_000,
            "context_max": 1_000_000,
            "context_percent": 14,
            "compressions": 2
        ]
        let usage = try XCTUnwrap(value.decoded(as: UsageStats.self))
        XCTAssertEqual(usage.contextUsed, 142_000)
        XCTAssertEqual(usage.contextMax, 1_000_000)
        XCTAssertEqual(usage.contextPercent, 14)
        XCTAssertEqual(usage.compressions, 2)
        // The pre-existing fields still decode.
        XCTAssertEqual(usage.total, 1200)
    }

    func testUsageStatsContextFieldsOptionalWhenAbsent() throws {
        // A usage block from a provider that doesn't report context occupancy.
        let value: JSONValue = ["input": 10, "output": 20, "total": 30]
        let usage = try XCTUnwrap(value.decoded(as: UsageStats.self))
        XCTAssertNil(usage.contextUsed)
        XCTAssertNil(usage.contextMax)
        XCTAssertNil(usage.contextPercent)
        XCTAssertNil(usage.compressions)
    }

    func testMessageCompletePayloadCarriesContextUsage() throws {
        // The end-to-end shape: message.complete's usage block on the wire.
        let payload: JSONValue = [
            "text": "done",
            "status": "completed",
            "usage": [
                "total": 500,
                "context_used": 50_000,
                "context_max": 200_000,
                "context_percent": 25,
                "compressions": 0
            ]
        ]
        let complete = try XCTUnwrap(payload.decoded(as: MessageCompletePayload.self))
        XCTAssertEqual(complete.usage?.contextUsed, 50_000)
        XCTAssertEqual(complete.usage?.contextPercent, 25)
        XCTAssertEqual(complete.usage?.compressions, 0)
    }

    func testSessionStatusResultCarriesContextUsage() throws {
        // The resume-seed source: session.status's usage block.
        let value: JSONValue = [
            "running": true,
            "model": "claude-x",
            "usage": [
                "context_used": 600_000,
                "context_max": 1_000_000,
                "context_percent": 60,
                "compressions": 3
            ]
        ]
        let status = try XCTUnwrap(value.decoded(as: SessionStatusResult.self))
        XCTAssertEqual(status.usage?.contextUsed, 600_000)
        XCTAssertEqual(status.usage?.contextPercent, 60)
        XCTAssertEqual(status.usage?.compressions, 3)
    }

    // MARK: - formatK

    func testFormatKContractExamples() {
        // The exact examples the contract specifies.
        XCTAssertEqual(UsageStats.formatK(142_000), "142K")
        XCTAssertEqual(UsageStats.formatK(1_000_000), "1M")
    }

    func testFormatKSubThousandVerbatim() {
        XCTAssertEqual(UsageStats.formatK(0), "0")
        XCTAssertEqual(UsageStats.formatK(1), "1")
        XCTAssertEqual(UsageStats.formatK(999), "999")
    }

    func testFormatKKeepsOneDecimalWhenNotWhole() {
        XCTAssertEqual(UsageStats.formatK(1_500), "1.5K")
        XCTAssertEqual(UsageStats.formatK(1_250_000), "1.3M")  // 1.25 → 1.3 (one-dp round)
        XCTAssertEqual(UsageStats.formatK(12_400), "12.4K")
    }

    func testFormatKDropsDecimalOnWholeUnits() {
        XCTAssertEqual(UsageStats.formatK(2_000), "2K")
        XCTAssertEqual(UsageStats.formatK(5_000_000), "5M")
    }

    func testFormatKBoundary() {
        XCTAssertEqual(UsageStats.formatK(1_000), "1K")
        XCTAssertEqual(UsageStats.formatK(999_999), "1000K")  // < 1M stays in the K band
    }

    // MARK: - ModelPicker stats line

    func testContextStatsLineWithCompressions() {
        let line = ModelPickerView.contextStatsLine(
            (used: 142_000, max: 1_000_000, percent: 14, compressions: 2)
        )
        XCTAssertEqual(line, "142K / 1M tokens · 14% · 2 compressions")
    }

    func testContextStatsLineSingularCompression() {
        let line = ModelPickerView.contextStatsLine(
            (used: 50_000, max: 200_000, percent: 25, compressions: 1)
        )
        XCTAssertEqual(line, "50K / 200K tokens · 25% · 1 compression")
    }

    func testContextStatsLineOmitsZeroCompressions() {
        let line = ModelPickerView.contextStatsLine(
            (used: 30_000, max: 1_000_000, percent: 3, compressions: 0)
        )
        XCTAssertEqual(line, "30K / 1M tokens · 3%")
    }

    // MARK: - Usage footer "ctx N" clause (H1.5)

    func testUsageLineAppendsContextWhenPresent() {
        let usage = makeUsage(total: 1234, costUsd: 0.0123, contextUsed: 142_000)
        XCTAssertEqual(
            MessageBubble.usageLine(usage),
            "1234 tokens · $0.0123 · ctx 142K"
        )
    }

    func testUsageLineOmitsContextWhenAbsent() {
        let usage = makeUsage(total: 1234, costUsd: 0.0123, contextUsed: nil)
        XCTAssertEqual(MessageBubble.usageLine(usage), "1234 tokens · $0.0123")
    }

    func testUsageLineContextOnlyTurn() {
        // A turn with no per-turn total but a context reading still shows ctx.
        let usage = makeUsage(total: nil, costUsd: nil, contextUsed: 50_000)
        XCTAssertEqual(MessageBubble.usageLine(usage), "ctx 50K")
    }

    // MARK: - Helpers

    /// Build a `UsageStats` via its JSON decode path (its memberwise init is
    /// synthesized but order-fragile; decoding mirrors the wire exactly).
    private func makeUsage(total: Int?, costUsd: Double?, contextUsed: Int?) -> UsageStats {
        var object: [String: JSONValue] = [:]
        if let total { object["total"] = .number(Double(total)) }
        if let costUsd { object["cost_usd"] = .number(costUsd) }
        if let contextUsed { object["context_used"] = .number(Double(contextUsed)) }
        return JSONValue.object(object).decoded(as: UsageStats.self)!
    }
}
