import XCTest
@testable import HermesMobile

/// Focused tests for STR-2 / ABH-421 / STR-241's iPad follow-up: the persisted
/// `transcriptSectionSubagentsEnabled` client preference must gate the
/// `RootView.SplitLayout` subagent inspector toggle/tab exactly like
/// `ChatView.showSubagentAffordance` gates the iPhone affordance, so disabling
/// the Subagents section hides the iPad inspector entry point too — not just
/// the iPhone one.
final class RootInspectorPolicyTests: XCTestCase {

    func testShowsOnlyWhenAllThreeConditionsHold() {
        XCTAssertTrue(
            RootInspectorPolicy.showSubagentInspector(
                sectionEnabled: true,
                subagentEventsAvailable: true,
                hasSubagentActivity: true
            )
        )
    }

    func testHiddenWhenSectionPreferenceDisabled() {
        // The regression this fix targets: even with a capable gateway and live
        // delegation activity, disabling the client-only Subagents section pref
        // must hide the iPad inspector toggle/tab.
        XCTAssertFalse(
            RootInspectorPolicy.showSubagentInspector(
                sectionEnabled: false,
                subagentEventsAvailable: true,
                hasSubagentActivity: true
            )
        )
    }

    func testHiddenWhenGatewayCapabilityUnavailable() {
        XCTAssertFalse(
            RootInspectorPolicy.showSubagentInspector(
                sectionEnabled: true,
                subagentEventsAvailable: false,
                hasSubagentActivity: true
            )
        )
    }

    func testHiddenWhenNoSubagentActivity() {
        XCTAssertFalse(
            RootInspectorPolicy.showSubagentInspector(
                sectionEnabled: true,
                subagentEventsAvailable: true,
                hasSubagentActivity: false
            )
        )
    }

    func testHiddenWhenAllConditionsFalse() {
        XCTAssertFalse(
            RootInspectorPolicy.showSubagentInspector(
                sectionEnabled: false,
                subagentEventsAvailable: false,
                hasSubagentActivity: false
            )
        )
    }
}
