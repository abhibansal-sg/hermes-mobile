import Foundation
import XCTest
@testable import HermesMobile

/// QA-2 R1a — APNs environment detection from `embedded.mobileprovision`.
///
/// Root cause on main 1fcffe3d5: `PushTokenPoster.apnsEnvironment` decoded the
/// profile with `String(data:encoding:.ascii)`. Swift's `.ascii` is STRICT —
/// any byte ≥ 0x80 → `nil` — and every SIGNED profile wraps its plist in a
/// binary CMS/PKCS#7 signature, so the decode ALWAYS failed and the fallback
/// stamped `"production"` on every dev-signed build. Sandbox device tokens
/// then routed to `api.push.apple.com` → 400 BadDeviceToken on every notify;
/// the phone received NOTHING. The simulator `#if` returns "sandbox" before
/// the profile is read, so no sim/E2E/conformance run ever caught it.
///
/// The fix parses the profile for real: binary-locate the `<?xml … </plist>`
/// span and `PropertyListSerialization`-read `Entitlements.aps-environment`.
/// These tests feed synthetic SIGNED-profile bytes (ASCII plist + DER/CMS
/// bytes ≥ 0x80) through the pure parser.
final class PushTokenPosterEnvTests: XCTestCase {

    /// A synthetic signed profile: the real XML entitlements plist wrapped in
    /// binary CMS/PKCS#7-style bytes (≥ 0x80), exactly the shape that made the
    /// old strict-ASCII decode return nil.
    private func signedProfile(apsEnvironment: String) -> Data {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key>
            <string>Hermes Agent</string>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>6J4Y9NKRQ2.ai.hermes.app</string>
                <key>aps-environment</key>
                <string>\(apsEnvironment)</string>
                <key>com.apple.security.application-groups</key>
                <array>
                    <string>group.ai.hermes.app</string>
                </array>
            </dict>
            <key>TeamIdentifier</key>
            <array>
                <string>6J4Y9NKRQ2</string>
            </array>
        </dict>
        </plist>
        """
        // DER/CMS envelope bytes (≥ 0x80 present) — the signature that breaks
        // strict charset decodes.
        var data = Data([0x30, 0x82, 0x1F, 0xC4, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
        data.append(Data(plist.utf8))
        data.append(Data([0xA0, 0x82, 0x1E, 0x9B, 0x30, 0x82, 0x19, 0xFF, 0xD9, 0x81, 0xC4]))
        return data
    }

    /// Regression record of the ROOT CAUSE: strict-ASCII decoding of real
    /// signed-profile bytes returns nil (→ old code fell back to "production").
    func testStrictAsciiDecodeFailsOnSignedProfileBytes() {
        XCTAssertNil(String(data: signedProfile(apsEnvironment: "development"), encoding: .ascii))
        XCTAssertNil(String(data: signedProfile(apsEnvironment: "production"), encoding: .ascii))
    }

    func testParsesDevelopmentEntitlementAsSandbox() {
        // THE R1a regression: dev-signed build → sandbox (old code: "production").
        XCTAssertEqual(
            PushTokenPoster.parseAPNsEnvironment(
                profileData: signedProfile(apsEnvironment: "development")
            ),
            "sandbox"
        )
    }

    func testParsesProductionEntitlementAsProduction() {
        // TestFlight/App Store profiles keep routing to the production host.
        XCTAssertEqual(
            PushTokenPoster.parseAPNsEnvironment(
                profileData: signedProfile(apsEnvironment: "production")
            ),
            "production"
        )
    }

    func testReturnsNilWithoutPlistSpan() {
        XCTAssertNil(PushTokenPoster.parseAPNsEnvironment(profileData: Data([0x30, 0x82, 0xFF])))
        XCTAssertNil(PushTokenPoster.parseAPNsEnvironment(profileData: Data()))
    }

    func testReturnsNilWhenPlistHasNoEntitlements() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>AppIDName</key><string>X</string></dict></plist>
        """
        XCTAssertNil(PushTokenPoster.parseAPNsEnvironment(profileData: Data(plist.utf8)))
    }

    func testReturnsNilWhenMalformedPlistBetweenMarkers() {
        var data = Data([0x80, 0x81])
        data.append(Data("<?xml <not really a plist".utf8))
        data.append(Data("</plist>".utf8))
        XCTAssertNil(PushTokenPoster.parseAPNsEnvironment(profileData: data))
    }

    /// The fail-safe direction: an unknown entitlement value parses to nil, so
    /// `apnsEnvironment`'s profile-exists-but-unreadable fallback (sandbox)
    /// applies — with QA-2 R1b eviction a wrong-host sandbox stamp self-heals,
    /// while a production mis-stamp on a dev build was unrecoverable.
    func testReturnsNilForUnknownEntitlementValue() {
        XCTAssertNil(
            PushTokenPoster.parseAPNsEnvironment(
                profileData: signedProfile(apsEnvironment: "weird-value")
            )
        )
    }
}
