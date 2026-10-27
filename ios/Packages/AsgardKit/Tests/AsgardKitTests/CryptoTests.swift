import CryptoKit
import Foundation
import Testing
@testable import AsgardKit

struct Vector: Codable {
    var recipient_identity_private, recipient_identity_public, sender_signing_seed, sender_signing_public: String
    var conversation_id, sender_device_id, client_id, plaintext, ciphertext, signature, wrapped_key: String
}

@Suite struct CryptoTests {
    @Test func envelopeRoundTrip() throws {
        let sender = DeviceKeys(), recipient = DeviceKeys()
        let conv = UUID(), dev = UUID(), client = UUID()
        let aad = E2EE.aad(conversation: conv, senderDevice: dev, clientID: client)
        let content = Data(#"{"v":1,"type":"text","text":"Hail"}"#.utf8)
        let sealed = try E2EE.seal(content, aad: aad)
        let sig = try E2EE.sign(sender.signing, aad: aad, ciphertext: sealed.ciphertext)
        let wrapped = try E2EE.wrap(sealed.key, for: recipient.identityPublic, clientID: client)
        #expect(wrapped.count == E2EE.wrappedKeySize)
        #expect(E2EE.verify(sender.signingPublic, aad: aad, ciphertext: sealed.ciphertext, signature: sig))
        let key = try E2EE.unwrap(wrapped, identity: recipient.identity, clientID: client)
        #expect(try E2EE.open(sealed.ciphertext, key: key, aad: aad) == content)
        #expect(throws: E2EE.Failure.decryptFailed) { try E2EE.unwrap(wrapped, identity: DeviceKeys().identity, clientID: client) }
        #expect(throws: E2EE.Failure.decryptFailed) {
            try E2EE.open(sealed.ciphertext, key: key, aad: E2EE.aad(conversation: UUID(), senderDevice: dev, clientID: client))
        }
    }

    @Test func aadUsesLowercaseIDs() {
        let id = UUID(uuidString: "6F1F5A4E-2B1C-4C8E-9A51-0C9B1B8F7A10")!
        let aad = E2EE.aad(conversation: id, senderDevice: id, clientID: id)
        #expect(String(decoding: aad, as: UTF8.self).contains("6f1f5a4e-2b1c"))
    }

    @Test func opensGoVector() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/go_vector", withExtension: "json"))
        let v = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        let identity = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: v.recipient_identity_private)!)
        #expect(identity.publicKey.rawRepresentation.base64EncodedString() == v.recipient_identity_public)
        let aad = E2EE.aad(conversation: UUID(uuidString: v.conversation_id)!, senderDevice: UUID(uuidString: v.sender_device_id)!,
                           clientID: UUID(uuidString: v.client_id)!)
        #expect(String(decoding: aad, as: UTF8.self) == "\(v.conversation_id)\0\(v.sender_device_id)\0\(v.client_id)")
        let ct = Data(base64Encoded: v.ciphertext)!
        #expect(E2EE.verify(Data(base64Encoded: v.sender_signing_public)!, aad: aad, ciphertext: ct, signature: Data(base64Encoded: v.signature)!))
        let key = try E2EE.unwrap(Data(base64Encoded: v.wrapped_key)!, identity: identity, clientID: UUID(uuidString: v.client_id)!)
        #expect(String(decoding: try E2EE.open(ct, key: key, aad: aad), as: UTF8.self) == v.plaintext)
    }

    /// Writes an envelope for the Go test suite (server/internal/e2ee TestSwiftVector).
    @Test func writeSwiftVector() throws {
        guard ProcessInfo.processInfo.environment["ASGARD_WRITE_VECTOR"] != nil else { return }
        let recipient = DeviceKeys(), sender = DeviceKeys()
        let conv = UUID(), dev = UUID(), client = UUID()
        let plaintext = #"{"v":1,"type":"text","text":"Hail from Swift"}"#
        let aad = E2EE.aad(conversation: conv, senderDevice: dev, clientID: client)
        let sealed = try E2EE.seal(Data(plaintext.utf8), aad: aad)
        let v = Vector(
            recipient_identity_private: recipient.identity.rawRepresentation.base64EncodedString(),
            recipient_identity_public: recipient.identityPublic.base64EncodedString(),
            sender_signing_seed: sender.signing.rawRepresentation.base64EncodedString(),
            sender_signing_public: sender.signingPublic.base64EncodedString(),
            conversation_id: conv.lower, sender_device_id: dev.lower, client_id: client.lower, plaintext: plaintext,
            ciphertext: sealed.ciphertext.base64EncodedString(),
            signature: try E2EE.sign(sender.signing, aad: aad, ciphertext: sealed.ciphertext).base64EncodedString(),
            wrapped_key: try E2EE.wrap(sealed.key, for: recipient.identityPublic, clientID: client).base64EncodedString())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/swift_vector.json")
        try enc.encode(v).write(to: out)
    }

    @Test(arguments: [0, 1, 1000, MediaCrypto.chunkSize, MediaCrypto.chunkSize + 1, MediaCrypto.chunkSize * 3 + 17])
    func mediaRoundTrip(size: Int) throws {
        let data = Data((0..<size).map { UInt8($0 % 251) })
        let r = try MediaCrypto.encrypt(data)
        #expect(try MediaCrypto.decrypt(r.blob, key: r.key, digest: r.digest) == data)
        if size > MediaCrypto.chunkSize {
            // Truncating to a chunk boundary must fail (final-chunk flag).
            let truncated = r.blob.prefix(12 + MediaCrypto.chunkSize + 16)
            #expect(throws: E2EE.Failure.self) { try MediaCrypto.decrypt(Data(truncated), key: r.key, digest: nil) }
        }
    }

    @Test func safetyNumberIsSymmetric() {
        let a = UUID(), b = UUID()
        let ka = [DeviceKeys().signingPublic], kb = [DeviceKeys().signingPublic, DeviceKeys().signingPublic]
        let n1 = SafetyNumber.compute(userA: a, keysA: ka, userB: b, keysB: kb)
        let n2 = SafetyNumber.compute(userA: b, keysA: kb, userB: a, keysB: ka)
        #expect(n1 == n2)
        #expect(n1.count == 35)
    }

    @Test func decodesGoDates() throws {
        let json = #"{"a":"2026-10-27T12:00:00.123456789Z","b":"2026-10-27T12:00:00Z","c":"2026-10-27T13:00:00+01:00"}"#
        let d = try Coding.decoder.decode([String: Date].self, from: Data(json.utf8))
        #expect(abs(d["a"]!.timeIntervalSince(d["b"]!) - 0.123) < 0.001)
        #expect(d["b"] == d["c"])
    }
}
