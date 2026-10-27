package com.giantmushroom.asgardchat.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.giantmushroom.asgardchat.crypto.DeviceKeys
import com.giantmushroom.asgardchat.net.AsgardJson
import com.giantmushroom.asgardchat.net.Bytes
import com.giantmushroom.asgardchat.net.Id
import kotlinx.serialization.Serializable
import java.security.KeyStore
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The signed-in account. Private keys are encrypted with a hardware-backed Android Keystore key. */
@Serializable
data class Account(
    val serverURL: String,
    val token: String,
    val userID: Id,
    val deviceID: Id,
    val identityPrivate: Bytes,
    val signingSeed: Bytes,
) {
    val keys: DeviceKeys get() = DeviceKeys(identityPrivate, signingSeed)
}

class AccountStore(context: Context) {
    private val prefs = context.getSharedPreferences("asgard-account", Context.MODE_PRIVATE)
    private val alias = "asgard-account-key"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return gen.generateKey()
    }

    fun load(): Account? {
        val blob = prefs.getString("account", null) ?: return null
        return runCatching {
            val raw = Base64.getDecoder().decode(blob)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw.copyOfRange(0, 12)))
            AsgardJson.decodeFromString(Account.serializer(), String(c.doFinal(raw.copyOfRange(12, raw.size))))
        }.getOrNull()
    }

    fun save(a: Account) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val sealed = c.iv + c.doFinal(AsgardJson.encodeToString(Account.serializer(), a).toByteArray())
        prefs.edit().putString("account", Base64.getEncoder().encodeToString(sealed)).apply()
    }

    fun clear() { prefs.edit().clear().apply() }

    /** The message history recovery key, sealed with the Keystore key like the account. */
    var recoveryKey: ByteArray?
        get() = prefs.getString("history", null)?.let { blob ->
            runCatching {
                val raw = Base64.getDecoder().decode(blob)
                val c = Cipher.getInstance("AES/GCM/NoPadding")
                c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw.copyOfRange(0, 12)))
                c.doFinal(raw.copyOfRange(12, raw.size))
            }.getOrNull()
        }
        set(v) {
            if (v == null) { prefs.edit().remove("history").apply(); return }
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.ENCRYPT_MODE, key())
            prefs.edit().putString("history", Base64.getEncoder().encodeToString(c.iv + c.doFinal(v))).apply()
        }

    var historyCursor: Long
        get() = prefs.getLong("historyCursor", 0)
        set(v) { prefs.edit().putLong("historyCursor", v).apply() }

    var cursor: Long
        get() = prefs.getLong("cursor", 0)
        set(v) { prefs.edit().putLong("cursor", v).apply() }

    var lastServer: String
        get() = prefs.getString("lastServer", "https://chat.giantmushroom.studio")!!
        set(v) { prefs.edit().putString("lastServer", v).apply() }

    fun newDeviceID(): UUID = UUID.randomUUID()
}
