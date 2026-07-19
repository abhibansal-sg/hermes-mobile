import CryptoKit
import Foundation

struct RelayV2RawKeyPair: Codable, Equatable, Sendable {
    let privateKey: Data
    let publicKey: Data
}

struct RelayV2ReceiveContext: Sendable {
    let expectedDestination: String
    let expectedSource: String?
    let nowMilliseconds: UInt64
    let seenMessageIDs: Set<String>
}

enum RelayV2Crypto {
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    static func generateAgreementKeyPair() -> RelayV2RawKeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return RelayV2RawKeyPair(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }

    static func generateSigningKeyPair() -> RelayV2RawKeyPair {
        let key = Curve25519.Signing.PrivateKey()
        return RelayV2RawKeyPair(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }

    static func agreementPublicKey(from privateKey: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }

    static func signingPublicKey(from privateKey: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }

    static func sealBaseMessage(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data,
        authenticatedData: Data
    ) throws -> (encapsulatedKey: Data, ciphertext: Data) {
        do {
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
            var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info)
            let ciphertext = try sender.seal(plaintext, authenticating: authenticatedData)
            return (sender.encapsulatedKey, ciphertext)
        } catch {
            throw RelayV2ProtocolError.unauthenticated
        }
    }

    static func openAuthenticatedMessage(
        encapsulatedKey: Data,
        ciphertext: Data,
        recipientPrivateKey: Data,
        senderPublicKey: Data,
        info: Data,
        authenticatedData: Data
    ) throws -> Data {
        do {
            let recipientKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientPrivateKey)
            let senderKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderPublicKey)
            var recipient = try HPKE.Recipient(
                privateKey: recipientKey,
                ciphersuite: suite,
                info: info,
                encapsulatedKey: encapsulatedKey,
                authenticatedBy: senderKey
            )
            return try recipient.open(ciphertext, authenticating: authenticatedData)
        } catch {
            throw RelayV2ProtocolError.unauthenticated
        }
    }

    static func sealAuthenticatedEnvelope(
        header: RelayV2OuterHeader,
        message: RelayV2SecureMessage,
        recipientPublicKey: Data,
        senderAgreementPrivateKey: Data,
        senderSigningPrivateKey: Data,
        purpose: RelayV2HPKEPurpose,
        direction: RelayV2HPKEDirection
    ) throws -> RelayV2OuterEnvelope {
        guard message.messageID == header.messageID,
              message.expiresAtMilliseconds == header.expiresAtMilliseconds else {
            throw RelayV2ProtocolError.invalidArgument(field: "mid")
        }
        do {
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
            let senderKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: senderAgreementPrivateKey)
            var sender = try HPKE.Sender(
                recipientKey: recipient,
                ciphersuite: suite,
                info: RelayV2Wire.hpkeInfo(purpose, direction),
                authenticatedBy: senderKey
            )
            let ciphertext = try sender.seal(
                message.canonicalJSON(),
                authenticating: header.authenticatedData
            )
            let signatureKey = try Curve25519.Signing.PrivateKey(rawRepresentation: senderSigningPrivateKey)
            let signature = try signatureKey.signature(
                for: header.signaturePayload(
                    encapsulatedKey: sender.encapsulatedKey,
                    ciphertext: ciphertext
                )
            )
            return try RelayV2OuterEnvelope(
                header: header,
                encapsulatedKey: sender.encapsulatedKey,
                ciphertext: ciphertext,
                signature: signature
            )
        } catch let error as RelayV2ProtocolError {
            throw error
        } catch {
            throw RelayV2ProtocolError.unauthenticated
        }
    }

    static func openAuthenticatedEnvelope(
        _ envelope: RelayV2OuterEnvelope,
        recipientPrivateKeys: [UInt32: Data],
        senderAgreementPublicKey: Data,
        senderSigningPublicKey: Data,
        expectedSenderKeyGeneration: UInt32,
        purpose: RelayV2HPKEPurpose,
        direction: RelayV2HPKEDirection,
        receive: RelayV2ReceiveContext
    ) throws -> RelayV2SecureMessage {
        do {
            let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: senderSigningPublicKey)
            guard signingKey.isValidSignature(
                envelope.signature,
                for: envelope.header.signaturePayload(
                    encapsulatedKey: envelope.encapsulatedKey,
                    ciphertext: envelope.ciphertext
                )
            ) else {
                throw RelayV2ProtocolError.unauthenticated
            }
            guard let privateKeyData = recipientPrivateKeys[envelope.header.recipientKeyGeneration] else {
                throw RelayV2ProtocolError.keyGenerationUnavailable(
                    envelope.header.recipientKeyGeneration
                )
            }
            guard envelope.header.destination == receive.expectedDestination,
                  receive.expectedSource.map({ $0 == envelope.header.source }) ?? true else {
                throw RelayV2ProtocolError.unauthenticated
            }
            guard envelope.header.expiresAtMilliseconds > receive.nowMilliseconds else {
                throw RelayV2ProtocolError.expired
            }
            guard !receive.seenMessageIDs.contains(envelope.header.messageID) else {
                throw RelayV2ProtocolError.replayDetected
            }
            let recipientKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
            let senderPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: senderAgreementPublicKey
            )
            var recipient = try HPKE.Recipient(
                privateKey: recipientKey,
                ciphersuite: suite,
                info: RelayV2Wire.hpkeInfo(purpose, direction),
                encapsulatedKey: envelope.encapsulatedKey,
                authenticatedBy: senderPublicKey
            )
            let plaintext = try recipient.open(
                envelope.ciphertext,
                authenticating: envelope.header.authenticatedData
            )
            let message = try RelayV2SecureMessage.decodeStrict(from: plaintext)
            guard message.messageID == envelope.header.messageID,
                  message.expiresAtMilliseconds == envelope.header.expiresAtMilliseconds,
                  message.senderKeyGeneration == expectedSenderKeyGeneration else {
                throw RelayV2ProtocolError.unauthenticated
            }
            return message
        } catch let error as RelayV2ProtocolError {
            throw error
        } catch {
            throw RelayV2ProtocolError.unauthenticated
        }
    }

    static func decryptNotificationPreview(
        descriptor: RelayV2NotificationDescriptor,
        recipientPrivateKey: Data,
        senderAgreementPublicKey: Data,
        nowMilliseconds: UInt64
    ) throws -> RelayV2NotificationPreview {
        guard descriptor.expiresAtMilliseconds > nowMilliseconds else {
            throw RelayV2ProtocolError.expired
        }
        do {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: recipientPrivateKey
            )
            let senderKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: senderAgreementPublicKey
            )
            var recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: suite,
                info: RelayV2Wire.hpkeInfo(.notification, .agentToDevice),
                encapsulatedKey: descriptor.previewEncapsulatedKey,
                authenticatedBy: senderKey
            )
            let plaintext = try recipient.open(
                descriptor.previewCiphertext,
                authenticating: descriptor.authenticatedData
            )
            let preview = try RelayV2NotificationPreview.decodeStrict(from: plaintext)
            guard preview.notificationID == descriptor.notificationID,
                  preview.notificationClass == descriptor.notificationClass,
                  preview.expiresAtMilliseconds == descriptor.expiresAtMilliseconds else {
                throw RelayV2ProtocolError.unauthenticated
            }
            return preview
        } catch let error as RelayV2ProtocolError {
            throw error
        } catch {
            throw RelayV2ProtocolError.unauthenticated
        }
    }

    static func encryptNotificationPreview(
        _ preview: RelayV2NotificationPreview,
        recipientPublicKey: Data,
        senderAgreementPrivateKey: Data,
        collapseID: String? = nil,
        sound: Bool = true
    ) throws -> RelayV2NotificationDescriptor {
        let placeholder = try RelayV2NotificationDescriptor(
            notificationClass: preview.notificationClass,
            notificationID: preview.notificationID,
            previewEncapsulatedKey: Data(repeating: 0, count: 32),
            previewCiphertext: Data(repeating: 0, count: 16),
            collapseID: collapseID,
            expiresAtMilliseconds: preview.expiresAtMilliseconds,
            sound: sound
        )
        do {
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
            let senderKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: senderAgreementPrivateKey
            )
            var sender = try HPKE.Sender(
                recipientKey: recipient,
                ciphersuite: suite,
                info: RelayV2Wire.hpkeInfo(.notification, .agentToDevice),
                authenticatedBy: senderKey
            )
            let ciphertext = try sender.seal(
                preview.canonicalJSON(),
                authenticating: placeholder.authenticatedData
            )
            return try RelayV2NotificationDescriptor(
                notificationClass: preview.notificationClass,
                notificationID: preview.notificationID,
                previewEncapsulatedKey: sender.encapsulatedKey,
                previewCiphertext: ciphertext,
                collapseID: collapseID,
                expiresAtMilliseconds: preview.expiresAtMilliseconds,
                sound: sound
            )
        } catch let error as RelayV2ProtocolError {
            throw error
        } catch {
            throw RelayV2ProtocolError.unauthenticated
        }
    }
}
