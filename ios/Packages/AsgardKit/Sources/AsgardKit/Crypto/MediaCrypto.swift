import CryptoKit
import Foundation

/// Chunked attachment encryption ("AGM1"), see docs/PROTOCOL.md.
public enum MediaCrypto {
    public static let magic = Data("AGM1".utf8)
    public static let chunkSize = 64 * 1024
    static let overhead = 16

    public struct Result: Sendable {
        public let blob: Data
        public let key: Data
        public let digest: Data
    }

    public static func encrypt(_ plaintext: Data) throws -> Result {
        let key = SymmetricKey(size: .bits256)
        var prefix = Data(count: 8)
        prefix.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        var out = magic + prefix
        out.reserveCapacity(plaintext.count + (plaintext.count / chunkSize + 1) * (overhead + 12) + 12)
        let chunks = max(1, Int((Double(plaintext.count) / Double(chunkSize)).rounded(.up)))
        for i in 0..<chunks {
            let start = plaintext.startIndex + i * chunkSize
            let end = min(start + chunkSize, plaintext.endIndex)
            let isFinal = i == chunks - 1
            let box = try ChaChaPoly.seal(plaintext[start..<end], using: key, nonce: nonce(prefix, i), authenticating: chunkAAD(i, isFinal))
            out.append(box.ciphertext)
            out.append(box.tag)
        }
        return Result(blob: out, key: key.withUnsafeBytes { Data($0) }, digest: Data(SHA256.hash(data: out)))
    }

    public static func decrypt(_ blob: Data, key keyData: Data, digest: Data?) throws -> Data {
        if let digest, Data(SHA256.hash(data: blob)) != digest { throw E2EE.Failure.decryptFailed }
        guard blob.count >= 12 + overhead, blob.prefix(4) == magic else { throw E2EE.Failure.decryptFailed }
        let key = SymmetricKey(data: keyData)
        let prefix = blob[blob.startIndex + 4 ..< blob.startIndex + 12]
        var offset = blob.startIndex + 12
        var out = Data()
        var i = 0
        let sealedChunk = chunkSize + overhead
        while offset < blob.endIndex {
            let end = min(offset + sealedChunk, blob.endIndex)
            let isFinal = end == blob.endIndex
            let body = blob[offset..<end]
            guard body.count >= overhead else { throw E2EE.Failure.decryptFailed }
            let box = try ChaChaPoly.SealedBox(nonce: nonce(Data(prefix), i), ciphertext: body.dropLast(overhead), tag: body.suffix(overhead))
            do {
                out.append(try ChaChaPoly.open(box, using: key, authenticating: chunkAAD(i, isFinal)))
            } catch {
                throw E2EE.Failure.decryptFailed
            }
            offset = end
            i += 1
        }
        return out
    }

    static func nonce(_ prefix: Data, _ i: Int) -> ChaChaPoly.Nonce {
        var n = prefix
        withUnsafeBytes(of: UInt32(i).bigEndian) { n.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: n)
    }

    static func chunkAAD(_ i: Int, _ isFinal: Bool) -> Data {
        var d = Data()
        withUnsafeBytes(of: UInt32(i).bigEndian) { d.append(contentsOf: $0) }
        d.append(isFinal ? 1 : 0)
        return d
    }
}
