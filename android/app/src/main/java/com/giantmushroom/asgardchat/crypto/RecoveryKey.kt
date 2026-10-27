package com.giantmushroom.asgardchat.crypto

import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.HKDFParameters

/**
 * 32-byte message history recovery key, written as 13 groups of 4 Crockford
 * base32 characters. Same format and derivation as AsgardKit's RecoveryKey.
 */
class RecoveryKey(val bytes: ByteArray) {
    val formatted: String
        get() {
            val out = StringBuilder()
            var bits = 0
            var value = 0
            for (b in bytes) {
                value = (value shl 8) or (b.toInt() and 0xff)
                bits += 8
                while (bits >= 5) { out.append(ALPHABET[(value shr (bits - 5)) and 31]); bits -= 5 }
                value = value and ((1 shl bits) - 1)
            }
            if (bits > 0) out.append(ALPHABET[(value shl (5 - bits)) and 31])
            return out.chunked(4).joinToString("-")
        }

    /** The history device's keys: whoever holds the recovery key can open history envelopes. */
    val deviceKeys: DeviceKeys get() = DeviceKeys(derive("identity"), derive("signing"))

    private fun derive(info: String): ByteArray {
        val g = HKDFBytesGenerator(SHA256Digest())
        g.init(HKDFParameters(bytes, "asgard-history-v1".toByteArray(), info.toByteArray()))
        return ByteArray(32).also { g.generateBytes(it, 0, 32) }
    }

    override fun equals(other: Any?) = other is RecoveryKey && other.bytes.contentEquals(bytes)
    override fun hashCode() = bytes.contentHashCode()

    companion object {
        private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

        fun generate() = RecoveryKey(E2EE.randomBytes(32))

        fun parse(text: String): RecoveryKey? {
            val out = java.io.ByteArrayOutputStream()
            var bits = 0
            var value = 0
            for (raw in text.uppercase()) {
                val ch = when (raw) { 'O' -> '0'; 'I', 'L' -> '1'; else -> raw }
                val i = ALPHABET.indexOf(ch)
                if (i < 0) { if (raw == '-' || raw.isWhitespace()) continue else return null }
                value = (value shl 5) or i
                bits += 5
                if (bits >= 8) { out.write((value shr (bits - 8)) and 0xff); bits -= 8; value = value and ((1 shl bits) - 1) }
            }
            val b = out.toByteArray()
            return if (b.size == 32) RecoveryKey(b) else null
        }
    }
}
