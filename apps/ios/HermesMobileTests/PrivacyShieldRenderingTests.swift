import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class PrivacyShieldRenderingTests: XCTestCase {
    private let sensitiveSentinels = [
        "SESSION_TITLE_SENTINEL",
        "MESSAGE_TEXT_SENTINEL",
        "INBOX_CONTENT_SENTINEL",
        "ATTACHMENT_PREVIEW_SENTINEL",
        "GATEWAY_IDENTITY_SENTINEL",
    ]

    func testInactiveAndBackgroundCoverRendersOpaqueWithoutSensitiveContent() throws {
        for phase in [ScenePhase.inactive, .background] {
            let coveredRenderer = ImageRenderer(content: ZStack {
                VStack {
                    ForEach(sensitiveSentinels, id: \.self, content: Text.init)
                }
                PrivacyShieldCover()
            }.frame(width: 320, height: 640))
            coveredRenderer.scale = 1
            let coveredImage = try XCTUnwrap(coveredRenderer.uiImage)

            let referenceRenderer = ImageRenderer(
                content: PrivacyShieldCover().frame(width: 320, height: 640)
            )
            referenceRenderer.scale = 1
            let referenceImage = try XCTUnwrap(referenceRenderer.uiImage)

            XCTAssertEqual(
                coveredImage.pngData(),
                referenceImage.pngData(),
                "sensitive sentinel pixels participated in the covered \(phase) snapshot"
            )
            let image = coveredImage
            let pixel = try XCTUnwrap(image.cgImage?.dataProvider?.data)
            let bytes = CFDataGetBytePtr(pixel)

            XCTAssertEqual(image.size, CGSize(width: 320, height: 640), "phase: \(phase)")
            XCTAssertEqual(bytes?[3], 255, "cover must be fully opaque in \(phase)")
        }
    }
}
