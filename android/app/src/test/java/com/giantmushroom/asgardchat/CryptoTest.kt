package com.giantmushroom.asgardchat

import com.giantmushroom.asgardchat.crypto.DeviceKeys
import com.giantmushroom.asgardchat.crypto.E2EE
import com.giantmushroom.asgardchat.crypto.MediaCrypto
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import java.util.UUID

class CryptoTest {
    private val b64 = Base64.getDecoder()

    /** Envelopes produced by the Go server code and by CryptoKit open here. */
    private fun opens(fixture: String) {
        val v = Json.parseToJsonElement(javaClass.classLoader!!.getResource(fixture)!!.readText()) as JsonObject
        fun s(k: String) = v[k]!!.jsonPrimitive.content
        val keys = DeviceKeys(b64.decode(s("recipient_identity_private")), ByteArray(32))
        assertEquals(s("recipient_identity_public"), Base64.getEncoder().encodeToString(keys.identityPublic))
        val aad = E2EE.aad(UUID.fromString(s("conversation_id")), UUID.fromString(s("sender_device_id")), UUID.fromString(s("client_id")))
        val ct = b64.decode(s("ciphertext"))
        assertTrue(E2EE.verify(b64.decode(s("sender_signing_public")), aad, ct, b64.decode(s("signature"))))
        assertFalse(E2EE.verify(b64.decode(s("sender_signing_public")), aad + 1, ct, b64.decode(s("signature"))))
        val key = E2EE.unwrap(b64.decode(s("wrapped_key")), keys.identityPrivate, UUID.fromString(s("client_id")))
        assertEquals(s("plaintext"), String(E2EE.open(ct, key, aad)))
    }

    @Test fun opensGoVector() = opens("go_vector.json")
    @Test fun opensSwiftVector() = opens("swift_vector.json")

    @Test fun roundTrip() {
        val sender = DeviceKeys.generate(); val recipient = DeviceKeys.generate()
        val conv = UUID.randomUUID(); val dev = UUID.randomUUID(); val client = UUID.randomUUID()
        val aad = E2EE.aad(conv, dev, client)
        val sealed = E2EE.seal("hello".toByteArray(), aad)
        val sig = E2EE.sign(sender.signingSeed, aad, sealed.ciphertext)
        assertTrue(E2EE.verify(sender.signingPublic, aad, sealed.ciphertext, sig))
        val wrapped = E2EE.wrap(sealed.key, recipient.identityPublic, client)
        assertEquals(92, wrapped.size)
        assertEquals("hello", String(E2EE.open(sealed.ciphertext, E2EE.unwrap(wrapped, recipient.identityPrivate, client), aad)))
    }

    @Test fun mediaRoundTrip() {
        for (n in listOf(0, 1, 1000, MediaCrypto.CHUNK, MediaCrypto.CHUNK + 1, MediaCrypto.CHUNK * 3 + 17)) {
            val data = E2EE.randomBytes(n)
            val r = MediaCrypto.encrypt(data)
            assertArrayEquals(data, MediaCrypto.decrypt(r.blob, r.key, r.digest))
        }
    }

    @Test(expected = E2EE.Failure::class)
    fun mediaRejectsTruncation() {
        val r = MediaCrypto.encrypt(E2EE.randomBytes(MediaCrypto.CHUNK * 2))
        MediaCrypto.decrypt(r.blob.copyOf(12 + MediaCrypto.CHUNK + 16), r.key, null)
    }
}

class RecoveryKeyTest {
    @org.junit.Test fun matchesCryptoKit() {
        val v = kotlinx.serialization.json.Json.parseToJsonElement(javaClass.classLoader!!.getResource("history_vector.json")!!.readText()) as kotlinx.serialization.json.JsonObject
        fun s(k: String) = (v[k] as kotlinx.serialization.json.JsonPrimitive).content
        val key = com.giantmushroom.asgardchat.crypto.RecoveryKey(java.util.Base64.getDecoder().decode(s("bytes")))
        org.junit.Assert.assertEquals(s("formatted"), key.formatted)
        org.junit.Assert.assertEquals(s("identity_public"), java.util.Base64.getEncoder().encodeToString(key.deviceKeys.identityPublic))
        org.junit.Assert.assertEquals(s("signing_public"), java.util.Base64.getEncoder().encodeToString(key.deviceKeys.signingPublic))
        org.junit.Assert.assertEquals(key, com.giantmushroom.asgardchat.crypto.RecoveryKey.parse(s("formatted").lowercase().replace("-", " ")))
        org.junit.Assert.assertNull(com.giantmushroom.asgardchat.crypto.RecoveryKey.parse("nope"))
    }
}
