import Foundation

// Generates swift-produced-secure-message.json from the production Swift wire
// types. This source is intentionally outside apps/ios: fixture regeneration
// does not modify the app. macOS CI regenerates/compares it; Python consumes
// only the checked-in bytes.
@main
struct SwiftProducedFixture {
    static func main() throws {
        let message = try RelayV2SecureMessage(
            messageID: "ABEiM0RVZneImaq7zN3u_w",
            kind: .streamAck,
            senderKeyGeneration: 7,
            createdAtMilliseconds: 1_784_449_900_000,
            expiresAtMilliseconds: 1_784_450_000_000,
            body: [
                "stream_id": "str_swift_produced",
                "through_seq": 17,
            ]
        )
        FileHandle.standardOutput.write(try message.canonicalJSON())
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
