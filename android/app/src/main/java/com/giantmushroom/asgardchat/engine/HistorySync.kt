package com.giantmushroom.asgardchat.engine

import com.giantmushroom.asgardchat.crypto.E2EE
import com.giantmushroom.asgardchat.crypto.RecoveryKey
import com.giantmushroom.asgardchat.net.ApiError
import com.giantmushroom.asgardchat.net.AsgardJson
import com.giantmushroom.asgardchat.net.Bytes
import com.giantmushroom.asgardchat.net.ConversationKind
import com.giantmushroom.asgardchat.net.MessageContent
import com.giantmushroom.asgardchat.net.SyncPage
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.Base64
import java.util.UUID

/** Message history sync on this device (see HistorySync.swift and server/internal/api/history.go). */
data class HistoryState(
    val enabled: Boolean? = null,
    val hasKey: Boolean = false,
    val working: Boolean = false,
    val progress: String? = null,
    val error: String? = null,
)

@Serializable
private data class HistoryStatus(
    val enabled: Boolean,
    @SerialName("identity_key") val identityKey: Bytes? = null,
)

private val ChatEngine.storedRecoveryKey: RecoveryKey? get() = accounts.recoveryKey?.let { RecoveryKey(it) }

suspend fun ChatEngine.refreshHistoryStatus() {
    val api = api ?: return
    val st = runCatching { api.send<HistoryStatus>("GET", "/me/history") }.getOrNull() ?: return
    val local = storedRecoveryKey
    if (local != null && st.enabled && !local.deviceKeys.identityPublic.contentEquals(st.identityKey)) accounts.recoveryKey = null
    history.update { it.copy(enabled = st.enabled, hasKey = st.enabled && storedRecoveryKey != null) }
}

fun ChatEngine.recoveryKeyForDisplay(): String? = storedRecoveryKey?.formatted

/** Turns history sync on with a fresh recovery key, which the caller shows to the user. */
suspend fun ChatEngine.enableHistory(): String {
    val api = api ?: throw ApiError.offline
    val key = RecoveryKey.generate()
    val k = key.deviceKeys
    api.call("PUT", "/me/history", buildJsonObject {
        put("identity_key", Base64.getEncoder().encodeToString(k.identityPublic))
        put("signing_key", Base64.getEncoder().encodeToString(k.signingPublic))
    })
    accounts.recoveryKey = key.bytes
    history.update { it.copy(enabled = true, hasKey = true) }
    clearDeviceCache()
    scope.launch { backfillHistory(); shareHistoryKey() }
    return key.formatted
}

suspend fun ChatEngine.restoreHistory(text: String) {
    val api = api ?: throw ApiError.offline
    val key = RecoveryKey.parse(text) ?: throw ApiError(0, "bad_key", "That doesn't look like a recovery key. It's 13 groups of 4 letters and numbers.")
    val st = api.send<HistoryStatus>("GET", "/me/history")
    if (!st.enabled) throw ApiError(0, "history_off", "Message history sync isn't turned on for this account.")
    if (!key.deviceKeys.identityPublic.contentEquals(st.identityKey)) throw ApiError(0, "wrong_key", "That recovery key doesn't match this account.")
    accounts.recoveryKey = key.bytes
    history.update { it.copy(enabled = true, hasKey = true) }
    importHistory()
}

suspend fun ChatEngine.disableHistory() {
    api?.call("DELETE", "/me/history")
    accounts.recoveryKey = null
    history.value = HistoryState(enabled = false)
    clearDeviceCache()
}

/** Downloads and decrypts everything wrapped for the history device. */
suspend fun ChatEngine.importHistory() {
    val api = api ?: return
    val key = storedRecoveryKey ?: return
    if (history.value.working) return
    val keys = key.deviceKeys
    history.update { it.copy(working = true, error = null) }
    var count = 0
    try {
        while (true) {
            val page = runCatching { api.send<SyncPage>("GET", "/me/history/messages", query = mapOf("after" to accounts.historyCursor.toString())) }.getOrNull()
                ?: run { history.update { it.copy(error = "Couldn't download history. It will retry later.") }; return }
            prefetchKeys(page.envelopes)
            page.envelopes.forEach { process(it, live = false, countUnread = false, openWith = keys) }
            count += page.envelopes.size
            history.update { it.copy(progress = "Restored $count messages…") }
            accounts.historyCursor = page.nextCursor
            if (!page.more) break
        }
    } finally {
        history.update { it.copy(working = false, progress = null) }
    }
}

/** Re-wraps keys of messages sent before history sync was on. Each device does this once per key. */
suspend fun ChatEngine.backfillHistory() {
    val api = api ?: return
    val a = account ?: return
    val rk = storedRecoveryKey ?: return
    val historyPublic = rk.deviceKeys.identityPublic
    val prefs = appPrefs()
    val flag = "historyBackfill-${a.deviceID}-${Base64.getEncoder().encodeToString(historyPublic).take(8)}"
    if (prefs.getBoolean(flag, false)) return
    val batch = mutableListOf<Pair<UUID, ByteArray>>()
    var total = 0
    suspend fun flush() {
        if (batch.isEmpty()) return
        val body = buildJsonObject {
            put("items", JsonArray(batch.map { (id, wk) -> buildJsonObject { put("message_id", id.toString()); put("wrapped_key", Base64.getEncoder().encodeToString(wk)) } }))
        }
        runCatching { total += Regex("\"added\"\\s*:\\s*(\\d+)").find(api.execute("POST", "/me/history/backfill", body.toString()))?.groupValues?.get(1)?.toInt() ?: 0 }
        batch.clear()
        history.update { it.copy(progress = "Backing up $total older messages…") }
    }
    for (c in dao.allConversations().filter { it.kindEnum != ConversationKind.community }) {
        var before: Long? = null
        while (true) {
            val envs = runCatching { api.history(UUID.fromString(c.id), before, 200) }.getOrNull() ?: break
            if (envs.isEmpty()) break
            for (env in envs) {
                val wk = env.wrappedKey ?: continue
                val k = runCatching { E2EE.unwrap(wk, a.identityPrivate, env.clientID) }.getOrNull() ?: continue
                batch += env.id to E2EE.wrap(k, historyPublic, env.clientID)
                if (batch.size >= 500) flush()
            }
            before = envs.minOf { it.seq }
            if (envs.size < 200) break
        }
    }
    flush()
    history.update { it.copy(progress = null) }
    prefs.edit().putBoolean(flag, true).apply()
}

/** Sends the recovery key to this account's other devices through the encrypted Saved Messages chat. */
fun ChatEngine.shareHistoryKey() {
    val key = storedRecoveryKey ?: return
    scope.launch {
        val saved = dao.allConversations().firstOrNull { it.kindEnum == ConversationKind.saved } ?: return@launch
        clearDeviceCache()
        runCatching { deliver(MessageContent(type = "history_key", historyKey = key.bytes), "control", saved.id) }
    }
}

suspend fun ChatEngine.receivedHistoryKey(data: ByteArray?, env: com.giantmushroom.asgardchat.net.Envelope) {
    if (data == null || env.senderUserID?.toString()?.lowercase() != myID || env.senderDeviceID?.toString()?.lowercase() == myDeviceID) return
    if (storedRecoveryKey != null) return
    val key = RecoveryKey(data)
    val st = runCatching { api!!.send<HistoryStatus>("GET", "/me/history") }.getOrNull() ?: return
    if (!st.enabled || !key.deviceKeys.identityPublic.contentEquals(st.identityKey)) return
    accounts.recoveryKey = key.bytes
    history.update { it.copy(enabled = true, hasKey = true) }
    importHistory()
}
