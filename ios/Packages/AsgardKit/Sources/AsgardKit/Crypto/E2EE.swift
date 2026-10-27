import CryptoKit
import Foundation

/// The v1 "fanout" envelope scheme. Mirrors `server/internal/e2ee` byte for byte;
/// see docs/PROTOCOL.md. All ids in AAD are lowercase UUID strings.
public enum E2EE {
    public static let wrapInfo = Data("asgard-wrap-v1".utf8)
    public static let wrappedKeySize = 92

    public enum Failure: Error, Equatable {
        case badKey, decryptFailed, badSignature
    }

    public struct Sealed: Sendable {
        public let key: SymmetricKey
        public let ciphertext: Data
    }

    public static func aad(conversation: UUID, senderDevice: UUID, clientID: UUID) -> Data {
        var d = Data(conversation.lower.utf8)
        d.append(0)
        d.append(contentsOf: senderDevice.lower.utf8)
        d.append(0)
        d.append(contentsOf: clientID.lower.utf8)
        return d
    }

    /// Encrypts `content` under a fresh message key.
    public static func seal(_ content: Data, aad: Data) throws -> Sealed {
        let key = SymmetricKey(size: .bits256)
        let box = try ChaChaPoly.seal(content, using: key, authenticating: aad)
        return Sealed(key: key, ciphertext: box.combined)
    }

    public static func open(_ ciphertext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: ciphertext), using: key, authenticating: aad)
        } catch {
            throw Failure.decryptFailed
        }
    }

    public static func sign(_ signer: Curve25519.Signing.PrivateKey, aad: Data, ciphertext: Data) throws -> Data {
        try signer.signature(for: digest(aad, ciphertext))
    }

    public static func verify(_ publicKey: Data, aad: Data, ciphertext: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: digest(aad, ciphertext))
    }

    /// Wraps a message key for one recipient device identity key (92 bytes).
    public static func wrap(_ messageKey: SymmetricKey, for recipientIdentity: Data, clientID: UUID) throws -> Data {
        guard let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientIdentity) else {
            throw Failure.badKey
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let ephPub = ephemeral.publicKey.rawRepresentation
        let wk = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephPub + recipientIdentity, sharedInfo: wrapInfo, outputByteCount: 32)
        let keyBytes = messageKey.withUnsafeBytes { Data($0) }
        let box = try ChaChaPoly.seal(keyBytes, using: wk, authenticating: Data(clientID.lower.utf8))
        return ephPub + box.combined
    }

    public static func unwrap(_ wrapped: Data, identity: Curve25519.KeyAgreement.PrivateKey, clientID: UUID) throws -> SymmetricKey {
        guard wrapped.count == wrappedKeySize else { throw Failure.decryptFailed }
        let ephPub = wrapped.prefix(32)
        guard let eph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPub),
              let shared = try? identity.sharedSecretFromKeyAgreement(with: eph) else {
            throw Failure.decryptFailed
        }
        let wk = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(ephPub) + identity.publicKey.rawRepresentation,
                                                sharedInfo: wrapInfo, outputByteCount: 32)
        do {
            let box = try ChaChaPoly.SealedBox(combined: wrapped.dropFirst(32))
            return SymmetricKey(data: try ChaChaPoly.open(box, using: wk, authenticating: Data(clientID.lower.utf8)))
        } catch {
            throw Failure.decryptFailed
        }
    }

    static func digest(_ aad: Data, _ ciphertext: Data) -> Data {
        var h = SHA256()
        h.update(data: aad)
        h.update(data: ciphertext)
        return Data(h.finalize())
    }
}

/// A device's long-term key material.
public struct DeviceKeys: Sendable {
    public let identity: Curve25519.KeyAgreement.PrivateKey
    public let signing: Curve25519.Signing.PrivateKey

    public init(identity: Curve25519.KeyAgreement.PrivateKey = .init(), signing: Curve25519.Signing.PrivateKey = .init()) {
        self.identity = identity
        self.signing = signing
    }

    public init(identityRaw: Data, signingRaw: Data) throws {
        identity = try .init(rawRepresentation: identityRaw)
        signing = try .init(rawRepresentation: signingRaw)
    }

    public var identityPublic: Data { identity.publicKey.rawRepresentation }
    public var signingPublic: Data { signing.publicKey.rawRepresentation }
}

extension UUID {
    /// Lowercase canonical form, as used by the server and in AAD.
    public var lower: String { uuidString.lowercased() }
}
