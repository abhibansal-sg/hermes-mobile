import XCTest

final class BackgroundConfigurationTests: XCTestCase {
    func testCanonicalPlistDeclaresFetchAndSilentPushWithoutProcessing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let plist = try Data(contentsOf: root.appendingPathComponent("HermesMobile/Info.plist"))
        let object = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        XCTAssertEqual(object["BGTaskSchedulerPermittedIdentifiers"] as? [String], ["ai.hermes.app.refresh"])
        XCTAssertEqual(
            Set(object["UIBackgroundModes"] as? [String] ?? []),
            ["fetch", "remote-notification"]
        )
        XCTAssertFalse(String(data: plist, encoding: .utf8)?.contains("processing") ?? true)

        let project = try String(contentsOf: root.appendingPathComponent("HermesMobile.xcodeproj/project.pbxproj"))
        XCTAssertTrue(project.contains("BackgroundRefreshCoordinator.swift in Sources"))
    }
}
