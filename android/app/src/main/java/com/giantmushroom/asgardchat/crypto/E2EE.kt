package com.giantmushroom.asgardchat.crypto

import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID

/**
 * The v1 "fanout" envelope scheme, byte-for-byte compatible with
 * server/internal/e2ee (Go) and AsgardKit's E2EE.swift. See docs/PROTOCOL.md.
 */
object E2EE {
    private val wrapInfo = "asgard-wrap-v1".toByteArray()
    const val WRAPPED_KEY_SIZE = 92
    private val random = SecureRandom()

    class Failure(message: String) : Exception(message)

    class Sealed(val key: ByteArray, val ciphertext: ByteArray)

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    /** All ids in AAD are lowercase canonical UUID strings. */
    fun aad(conversation: UUID, senderDevice: UUID, clientID: UUID): ByteArray =
        (conversation.lower() + "\u0000" + senderDevice.lower() + "\u0000" + clientID.lower()).toByteArray()

    /** Encrypts content under a fresh message key; ciphertext = nonce || body || tag. */
    fun seal(content: ByteArray, aad: ByteArray): Sealed {
        val key = randomBytes(32)
        return Sealed(key, aeadSeal(key, randomBytes(12), content, aad))
    }

    fun open(ciphertext: ByteArray, key: ByteArray, aad: ByteArray): ByteArray = aeadOpen(key, ciphertext, aad)

    fun sign(signingSeed: ByteArray, aad: ByteArray, ciphertext: ByteArray): ByteArray {
        val s = Ed25519Signer()
        s.init(true, Ed25519PrivateKeyParameters(signingSeed, 0))
        val d = digest(aad, ciphertext)
        s.update(d, 0, d.size)
        return s.generateSignature()
    }

    fun verify(publicKey: ByteArray, aad: ByteArray, ciphertext: ByteArray, signature: ByteArray): Boolean = runCatching {
        val v = Ed25519Signer()
        v.init(false, Ed25519PublicKeyParameters(publicKey, 0))
        val d = digest(aad, ciphertext)
        v.update(d, 0, d.size)
        v.verifySignature(signature)
    }.getOrDefault(false)

    /** Wraps a message key for one recipient device identity key (92 bytes). */
    fun wrap(messageKey: ByteArray, recipientIdentity: ByteArray, clientID: UUID): ByteArray {
        val eph = X25519PrivateKeyParameters(random)
        val ephPub = eph.generatePublicKey().encoded
        val shared = agree(eph, recipientIdentity)
        val wk = hkdf(shared, ephPub + recipientIdentity)
        return ephPub + aeadSeal(wk, randomBytes(12), messageKey, clientID.lower().toByteArray())
    }

    fun unwrap(wrapped: ByteArray, identityPrivate: ByteArray, clientID: UUID): ByteArray {
        if (wrapped.size != WRAPPED_KEY_SIZE) throw Failure("bad wrapped key")
        val identity = X25519PrivateKeyParameters(identityPrivate, 0)
        val ephPub = wrapped.copyOfRange(0, 32)
        val shared = agree(identity, ephPub)
        val wk = hkdf(shared, ephPub + identity.generatePublicKey().encoded)
        return aeadOpen(wk, wrapped.copyOfRange(32, wrapped.size), clientID.lower().toByteArray())
    }

    private fun agree(priv: X25519PrivateKeyParameters, pub: ByteArray): ByteArray {
        val a = X25519Agreement()
        a.init(priv)
        val out = ByteArray(a.agreementSize)
        a.calculateAgreement(X25519PublicKeyParameters(pub, 0), out, 0)
        return out
    }

    private fun hkdf(ikm: ByteArray, salt: ByteArray): ByteArray {
        val g = HKDFBytesGenerator(SHA256Digest())
        g.init(HKDFParameters(ikm, salt, wrapInfo))
        return ByteArray(32).also { g.generateBytes(it, 0, 32) }
    }

    /** ChaCha20-Poly1305 in CryptoKit "combined" form: nonce(12) || ciphertext || tag(16). */
    fun aeadSeal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray = nonce + aeadRaw(true, key, nonce, plaintext, aad)

    fun aeadOpen(key: ByteArray, combined: ByteArray, aad: ByteArray): ByteArray {
        if (combined.size < 28) throw Failure("ciphertext too short")
        return aeadRaw(false, key, combined.copyOfRange(0, 12), combined.copyOfRange(12, combined.size), aad)
    }

    /** Raw AEAD without the nonce prefix (used by media chunks). */
    fun aeadRaw(encrypt: Boolean, key: ByteArray, nonce: ByteArray, input: ByteArray, aad: ByteArray): ByteArray {
        val c = ChaCha20Poly1305()
        c.init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, aad))
        val out = ByteArray(c.getOutputSize(input.size))
        return try {
            val n = c.processBytes(input, 0, input.size, out, 0)
            val total = n + c.doFinal(out, n)
            if (total == out.size) out else out.copyOf(total)
        } catch (e: Exception) {
            throw Failure("decrypt failed")
        }
    }

    fun digest(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        parts.forEach { md.update(it) }
        return md.digest()
    }
}

/** A device's long-term keys: X25519 identity and Ed25519 signing seed (32 bytes each). */
class DeviceKeys(val identityPrivate: ByteArray, val signingSeed: ByteArray) {
    val identityPublic: ByteArray get() = X25519PrivateKeyParameters(identityPrivate, 0).generatePublicKey().encoded
    val signingPublic: ByteArray get() = Ed25519PrivateKeyParameters(signingSeed, 0).generatePublicKey().encoded

    companion object {
        fun generate(): DeviceKeys = DeviceKeys(X25519PrivateKeyParameters(SecureRandom()).encoded, Ed25519PrivateKeyParameters(SecureRandom()).encoded)
    }
}

/** Chunked attachment encryption ("AGM1"), see docs/PROTOCOL.md. */
object MediaCrypto {
    private val magic = "AGM1".toByteArray()
    const val CHUNK = 64 * 1024
    private const val TAG = 16

    class Result(val blob: ByteArray, val key: ByteArray, val digest: ByteArray)

    fun encrypt(plaintext: ByteArray): Result {
        val key = E2EE.randomBytes(32)
        val prefix = E2EE.randomBytes(8)
        val out = java.io.ByteArrayOutputStream(plaintext.size + (plaintext.size / CHUNK + 1) * TAG + 12)
        out.write(magic); out.write(prefix)
        val chunks = maxOf(1, (plaintext.size + CHUNK - 1) / CHUNK)
        for (i in 0 until chunks) {
            val start = i * CHUNK
            val end = minOf(start + CHUNK, plaintext.size)
            out.write(E2EE.aeadRaw(true, key, nonce(prefix, i), plaintext.copyOfRange(start, end), chunkAAD(i, i == chunks - 1)))
        }
        val blob = out.toByteArray()
        return Result(blob, key, E2EE.digest(blob))
    }

    fun decrypt(blob: ByteArray, key: ByteArray, digest: ByteArray?): ByteArray {
        if (digest != null && !E2EE.digest(blob).contentEquals(digest)) throw E2EE.Failure("digest mismatch")
        if (blob.size < 12 + TAG || !blob.copyOfRange(0, 4).contentEquals(magic)) throw E2EE.Failure("not an AGM1 blob")
        val prefix = blob.copyOfRange(4, 12)
        val out = java.io.ByteArrayOutputStream(blob.size)
        var offset = 12
        var i = 0
        while (offset < blob.size) {
            val end = minOf(offset + CHUNK + TAG, blob.size)
            out.write(E2EE.aeadRaw(false, key, nonce(prefix, i), blob.copyOfRange(offset, end), chunkAAD(i, end == blob.size)))
            offset = end
            i++
        }
        return out.toByteArray()
    }

    private fun nonce(prefix: ByteArray, i: Int) = prefix + be32(i)
    private fun chunkAAD(i: Int, final: Boolean) = be32(i) + byteArrayOf(if (final) 1 else 0)
    private fun be32(i: Int) = byteArrayOf((i ushr 24).toByte(), (i ushr 16).toByte(), (i ushr 8).toByte(), i.toByte())
}

fun UUID.lower(): String = toString().lowercase()
