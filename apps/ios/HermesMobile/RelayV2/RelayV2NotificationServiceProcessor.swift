import Foundation
import UserNotifications

/// Pure, synchronously bounded entrypoint used by the Notification Service
/// Extension. Keeping the policy outside the extension subclass makes the
/// decrypt/fallback/category contract executable in the simulator test target.
struct RelayV2NotificationServiceProcessor {
    private let loadPreviewKeys: () throws -> [RelayV2PreviewKeyRecord]
    private let nowMilliseconds: () -> UInt64

    init(
        keyStore: RelayV2KeychainStore = .init(),
        nowMilliseconds: @escaping () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.loadPreviewKeys = { try keyStore.loadAllPreviewKeys() }
        self.nowMilliseconds = nowMilliseconds
    }

    init(
        loadPreviewKeys: @escaping () throws -> [RelayV2PreviewKeyRecord],
        nowMilliseconds: @escaping () -> UInt64
    ) {
        self.loadPreviewKeys = loadPreviewKeys
        self.nowMilliseconds = nowMilliseconds
    }

    func render(_ source: UNNotificationContent) -> UNMutableNotificationContent {
        let fallback = Self.genericFallback(from: source)
        guard let descriptor = try? Self.descriptor(from: source.userInfo),
              let keys = try? loadPreviewKeys() else { return fallback }

        let now = nowMilliseconds()
        for key in keys {
            for localKey in key.activePrivateKeys(nowMilliseconds: now) {
                for remoteKey in key.activeAgentAgreementKeys(nowMilliseconds: now) {
                    guard let preview = try? RelayV2Crypto.decryptNotificationPreview(
                        descriptor: descriptor,
                        recipientPrivateKey: localKey.privateKey,
                        senderAgreementPublicKey: remoteKey.publicKey,
                        nowMilliseconds: now
                    ) else { continue }
                    let content = fallback.mutableCopy() as! UNMutableNotificationContent
                    content.title = preview.title
                    content.body = preview.body
                    content.threadIdentifier = preview.threadToken
                    content.sound = descriptor.sound ? .default : nil
                    content.categoryIdentifier = Self.approvedCategory(
                        preview.category,
                        notificationClass: preview.notificationClass,
                        action: preview.action
                    )
                    content.userInfo = preview.action == nil
                        ? [:]
                        : Self.authenticatedUserInfo(descriptor: descriptor)
                    return content
                }
            }
        }
        return fallback
    }

    static func genericFallback(
        from source: UNNotificationContent
    ) -> UNMutableNotificationContent {
        let content = source.mutableCopy() as! UNMutableNotificationContent
        content.title = "Hermes"
        content.body = "Open Hermes to view this update."
        content.subtitle = ""
        content.threadIdentifier = ""
        content.categoryIdentifier = ""
        content.sound = nil
        content.badge = nil
        content.interruptionLevel = .active
        content.relevanceScore = 0
        content.targetContentIdentifier = ""
        content.summaryArgument = ""
        content.summaryArgumentCount = 0
        content.launchImageName = ""
        content.attachments = []
        content.userInfo = [:]
        return content
    }

    static func descriptor(
        from userInfo: [AnyHashable: Any]
    ) throws -> RelayV2NotificationDescriptor {
        guard (userInfo["h_v"] as? NSNumber)?.intValue == RelayV2.protocolVersion,
              let className = userInfo["class"] as? String,
              let notificationClass = RelayV2NotificationClass(rawValue: className),
              let notificationID = userInfo["nid"] as? String,
              let encapsulated = userInfo["enc"] as? String,
              let ciphertext = userInfo["ct"] as? String,
              let expiry = (userInfo["exp"] as? NSNumber)?.uint64Value,
              let sound = userInfo["sound"] as? Bool else {
            throw RelayV2ProtocolError.invalidArgument(field: "push_descriptor")
        }
        let collapse: String?
        if userInfo["collapse"] is NSNull || userInfo["collapse"] == nil {
            collapse = nil
        } else {
            collapse = userInfo["collapse"] as? String
            guard collapse != nil else {
                throw RelayV2ProtocolError.invalidArgument(field: "collapse")
            }
        }
        return try RelayV2NotificationDescriptor(
            notificationClass: notificationClass,
            notificationID: notificationID,
            previewEncapsulatedKey: RelayV2Wire.decodeBase64URL(
                encapsulated,
                exactBytes: 32
            ),
            previewCiphertext: RelayV2Wire.decodeBase64URL(
                ciphertext,
                minimumBytes: 16,
                maximumBytes: 4_096
            ),
            collapseID: collapse,
            expiresAtMilliseconds: expiry,
            sound: sound
        )
    }

    /// HRP/2 deliberately has no inline clarification reply. Only an
    /// authenticated approval preview may install the two protected actions.
    static func approvedCategory(
        _ category: String?,
        notificationClass: RelayV2NotificationClass,
        action: [String: JSONValue]?
    ) -> String {
        guard notificationClass == .approval,
              category == "HERMES_APPROVAL",
              let action,
              Set(action.keys) == [
                "request_id", "session_id", "capability", "allowed_decisions",
                "destructive", "device_id", "device_generation",
              ],
              let capability = action["capability"]?.stringValue,
              RelayV2Wire.isToken(capability),
              let sessionID = action["session_id"]?.stringValue,
              RelayV2Wire.isToken(sessionID),
              let requestID = action["request_id"]?.stringValue,
              RelayV2Wire.isToken(requestID),
              let deviceID = action["device_id"]?.stringValue,
              RelayV2Wire.isToken(deviceID),
              action["device_generation"]?.intValue.map({ $0 > 0 }) == true,
              action["destructive"]?.boolValue != nil,
              let decisions = action["allowed_decisions"]?.arrayValue?.compactMap(\.stringValue),
              decisions.count == action["allowed_decisions"]?.arrayValue?.count,
              !decisions.isEmpty,
              Set(decisions).count == decisions.count,
              Set(decisions).isSubset(of: ["approve_once", "deny"]) else { return "" }
        return "HERMES_APPROVAL"
    }

    static func authenticatedUserInfo(
        descriptor: RelayV2NotificationDescriptor
    ) -> [AnyHashable: Any] {
        [
            "h_v": RelayV2.protocolVersion,
            "class": descriptor.notificationClass.rawValue,
            "nid": descriptor.notificationID,
            "enc": RelayV2Wire.base64URL(descriptor.previewEncapsulatedKey),
            "ct": RelayV2Wire.base64URL(descriptor.previewCiphertext),
            "exp": descriptor.expiresAtMilliseconds,
            "collapse": descriptor.collapseID ?? NSNull(),
            "sound": descriptor.sound,
        ]
    }
}
