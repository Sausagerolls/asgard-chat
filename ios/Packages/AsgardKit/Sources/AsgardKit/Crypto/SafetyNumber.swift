import CryptoKit
import Foundation

/// Safety numbers let two people confirm no one has swapped their keys.
public enum SafetyNumber {
    /// 30 digits in 6 groups of 5, identical on both sides.
    public static func compute(userA: UUID, keysA: [Data], userB: UUID, keysB: [Data]) -> String {
        func block(_ user: UUID, _ keys: [Data]) -> Data {
            var d = Data(user.lower.utf8)
            for k in keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) { d.append(k) }
            return d
        }
        let blocks = [block(userA, keysA), block(userB, keysB)].sorted { $0.lexicographicallyPrecedes($1) }
        var h = SHA256()
        blocks.forEach { h.update(data: $0) }
        let digest = Array(h.finalize())
        var digits = ""
        var i = 0
        while digits.count < 30 {
            let chunk = digest[i..<min(i + 5, digest.count)]
            var v: UInt64 = 0
            for b in chunk { v = (v << 8) | UInt64(b) }
            digits += String(format: "%05llu", v % 100_000)
            i += 5
        }
        return stride(from: 0, to: 30, by: 5).map { idx in
            let s = digits.index(digits.startIndex, offsetBy: idx)
            return String(digits[s..<digits.index(s, offsetBy: 5)])
        }.joined(separator: " ")
    }
}
