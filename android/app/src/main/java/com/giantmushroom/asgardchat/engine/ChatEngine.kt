package com.giantmushroom.asgardchat.engine

import android.content.Context
import android.os.Build
import com.giantmushroom.asgardchat.crypto.E2EE
import com.giantmushroom.asgardchat.crypto.MediaCrypto
import com.giantmushroom.asgardchat.data.Account
import com.giantmushroom.asgardchat.data.AccountStore
import com.giantmushroom.asgardchat.data.AsgardDatabase
import com.giantmushroom.asgardchat.data.CallEntity
import com.giantmushroom.asgardchat.data.ConversationEntity
import com.giantmushroom.asgardchat.data.MessageEntity
import com.giantmushroom.asgardchat.data.MessageStatus
import com.giantmushroom.asgardchat.data.PendingOpEntity
import com.giantmushroom.asgardchat.data.Reaction
import com.giantmushroom.asgardchat.data.UserEntity
import com.giantmushroom.asgardchat.net.ApiClient
import com.giantmushroom.asgardchat.net.ApiError
import com.giantmushroom.asgardchat.net.AsgardJson
import com.giantmushroom.asgardchat.net.CallJoin
import com.giantmushroom.asgardchat.net.ConnectionState
import com.giantmushroom.asgardchat.net.Conversation
import com.giantmushroom.asgardchat.net.ConversationKind
import com.giantmushroom.asgardchat.net.DeviceInfo
import com.giantmushroom.asgardchat.net.DeviceRegistration
import com.giantmushroom.asgardchat.net.Envelope
import com.giantmushroom.asgardchat.net.Member
import com.giantmushroom.asgardchat.net.MemberRole
import com.giantmushroom.asgardchat.net.MessageContent
import com.giantmushroom.asgardchat.net.Realtime
import com.giantmushroom.asgardchat.net.RealtimeEvent
import com.giantmushroom.asgardchat.net.SendRequest
import com.giantmushroom.asgardchat.net.ServerInfo
import com.giantmushroom.asgardchat.net.Session
import com.giantmushroom.asgardchat.net.User
import com.giantmushroom.asgardchat.net.VoiceJoin
import com.giantmushroom.asgardchat.net.VoiceParticipant
import com.giantmushroom.asgardchat.net.VoiceRoomState
import com.giantmushroom.asgardchat.net.lower
import kotlinx.coroutines.CoroutineScope
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

enum class Phase { Loading, SignedOut, Ready }

data class IncomingCall(val id: UUID, val conversationID: UUID, val callerID: UUID, val callerName: String, val video: Boolean)

class OutgoingFile(val data: ByteArray, val mime: String, val name: String? = null, val width: Int? = null, val height: Int? = null,
                   val durationMS: Int? = null, val waveform: ByteArray? = null, val thumbnail: ByteArray? = null)

/**
 * Sync, encryption and local storage for one signed-in device. Mirrors
 * AsgardKit's ChatEngine on iOS: same wire protocol, same message semantics.
 */
class ChatEngine(private val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val db = AsgardDatabase.open(context)
    val dao = db.dao()
    val accounts = AccountStore(context)

    val phase = MutableStateFlow(Phase.Loading)
    val me = MutableStateFlow<User?>(null)
    val serverInfo = MutableStateFlow<ServerInfo?>(null)
    val connection = MutableStateFlow(ConnectionState.disconnected)
    /** conversation -> user -> expiry (ms). */
    val typing = MutableStateFlow<Map<String, Map<String, Long>>>(emptyMap())
    val presence = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val readMarks = MutableStateFlow<Map<String, Map<String, Long>>>(emptyMap())
    val voiceRooms = MutableStateFlow<Map<String, List<VoiceParticipant>>>(emptyMap())
    val banner = MutableStateFlow<String?>(null)
    val incomingCall = MutableStateFlow<IncomingCall?>(null)
    val history = MutableStateFlow(HistoryState())
    private val _callEnded = MutableSharedFlow<UUID>(extraBufferCapacity = 8)
    val callEnded: SharedFlow<UUID> = _callEnded
    private val _incoming = MutableSharedFlow<MessageEntity>(extraBufferCapacity = 64)
    /** New messages from others over the live connection (for notifications). */
    val incomingMessages: SharedFlow<MessageEntity> = _incoming

    var account: Account? = null; private set
    var api: ApiClient? = null; private set
    private var realtime: Realtime? = null
    private val jobs = mutableListOf<Job>()
    private val syncLock = Mutex()
    private val signingKeys = ConcurrentHashMap<String, ByteArray>()
    private val deviceCache = ConcurrentHashMap<String, List<DeviceInfo>>()
    private val userFetches = ConcurrentHashMap.newKeySet<String>()
    private val users = ConcurrentHashMap<String, User>()
    private var lastTypingSent = mutableMapOf<String, Long>()
    val callKeys = ConcurrentHashMap<String, ByteArray>()
    var activeConversation: String? = null
    var currentVoiceRoom: String? = null

    val myID: String? get() = me.value?.id?.lower ?: account?.userID?.lower
    val myDeviceID: String? get() = account?.deviceID?.lower

    private val mediaDir: File get() = File(context.cacheDir, "media").apply { mkdirs() }

    // region Lifecycle

    fun start() {
        val a = accounts.load()
        if (a == null) { phase.value = Phase.SignedOut; return }
        activate(a, null)
    }

    private fun activate(a: Account, user: User?) {
        account = a
        api = ApiClient(a.serverURL, a.token)
        scope.launch {
            me.value = user ?: dao.user(a.userID.lower)?.user
            dao.usersFlow().collect { list -> list.forEach { u -> u.user?.let { users[u.id] = it } } }
        }
        phase.value = Phase.Ready
        connectRealtime()
        jobs += scope.launch {
            refreshAll(); syncNow(); refreshVoiceRooms()
            refreshHistoryStatus()
            if (history.value.hasKey) { importHistory(); backfillHistory() }
        }
        jobs += scope.launch { while (isActive) { dao.purgeExpired(System.currentTimeMillis()); expireTyping(); delay(5_000) } }
    }

    private fun connectRealtime() {
        val api = api ?: return
        val rt = Realtime(api, scope)
        realtime = rt
        jobs += scope.launch { rt.events.collect { handle(it) } }
        jobs += scope.launch {
            rt.state.collect { s ->
                val wasOffline = connection.value != ConnectionState.connected
                connection.value = s
                if (s == ConnectionState.connected && wasOffline) { syncNow(); refreshVoiceRooms() }
            }
        }
        rt.start()
    }

    fun foreground() {
        realtime?.nudge()
        scope.launch { syncNow() }
    }

    suspend fun refreshAll() {
        val api = api ?: return
        try {
            serverInfo.value = api.info()
            val u: User = api.send("GET", "/me")
            me.value = u
            store(u)
            refreshConversations()
            repairOnce()
        } catch (e: ApiError) {
            if (e.status == 401) signOut()
        }
    }

    // endregion

    // region Account

    val platform = "android"
    val deviceName: String get() = Build.MODEL ?: "Android"

    suspend fun signUp(server: String, invite: String, username: String, displayName: String, password: String) {
        val keys = com.giantmushroom.asgardchat.crypto.DeviceKeys.generate()
        val session: Session = ApiClient(server, null).send("POST", "/auth/register", buildJsonObject {
            put("invite", invite); put("username", username); put("password", password); put("display_name", displayName)
            put("device", AsgardJson.encodeToJsonElement(DeviceRegistration.serializer(), DeviceRegistration(deviceName, platform, keys.identityPublic, keys.signingPublic)))
        })
        finish(server, session, keys)
    }

    suspend fun signIn(server: String, username: String, password: String) {
        val keys = com.giantmushroom.asgardchat.crypto.DeviceKeys.generate()
        val session: Session = ApiClient(server, null).send("POST", "/auth/login", buildJsonObject {
            put("username", username); put("password", password)
            put("device", AsgardJson.encodeToJsonElement(DeviceRegistration.serializer(), DeviceRegistration(deviceName, platform, keys.identityPublic, keys.signingPublic)))
        })
        finish(server, session, keys)
    }

    suspend fun claimDeviceLink(server: String, code: String) {
        val keys = com.giantmushroom.asgardchat.crypto.DeviceKeys.generate()
        val session: Session = ApiClient(server, null).send("POST", "/devices/link/claim", buildJsonObject {
            put("code", code)
            put("device", AsgardJson.encodeToJsonElement(DeviceRegistration.serializer(), DeviceRegistration(deviceName, platform, keys.identityPublic, keys.signingPublic)))
        })
        finish(server, session, keys)
    }

    private suspend fun finish(server: String, s: Session, keys: com.giantmushroom.asgardchat.crypto.DeviceKeys) {
        val a = Account(server.trimEnd('/'), s.token, s.user.id, s.deviceID, keys.identityPrivate, keys.signingSeed)
        accounts.save(a)
        accounts.cursor = 0
        store(s.user)
        activate(a, s.user)
    }

    suspend fun signOut() {
        runCatching { api?.call("POST", "/auth/logout") }
        realtime?.stop()
        jobs.forEach { it.cancel() }
        jobs.clear()
        accounts.clear()
        withContext(Dispatchers.IO) { db.clearAllTables() }
        mediaDir.deleteRecursively()
        account = null; api = null; realtime = null
        serverInfo.value = null // the next account may be on another server
        me.value = null
        phase.value = Phase.SignedOut
    }

    // endregion

    // region Users and conversations

    fun user(id: String?): User? = id?.let { users[it] }

    fun name(id: String?): String {
        if (id == null) return "Asgard"
        if (id == myID) return "You"
        users[id]?.let { return it.displayName }
        if (userFetches.add(id)) scope.launch { runCatching { store(api!!.send<User>("GET", "/users/$id")) } }
        return "…"
    }

    suspend fun store(u: User) {
        users[u.id.lower] = u
        dao.upsert(UserEntity(u.id.lower, AsgardJson.encodeToString(User.serializer(), u), u.displayName, u.username))
        if (u.id.lower == myID) me.value = u
    }

    /** Updates name, bio and (unencrypted, like every avatar) profile photo. */
    suspend fun updateProfile(displayName: String? = null, bio: String? = null, avatarJpeg: ByteArray? = null) {
        val api = api ?: throw ApiError.offline
        val avatarID = avatarJpeg?.let { api.upload(it, purpose = "avatar", contentType = "image/jpeg") }
        val u: User = api.send("PATCH", "/me", buildJsonObject {
            displayName?.let { put("display_name", it) }; bio?.let { put("bio", it) }; avatarID?.let { put("avatar_media_id", it.toString()) }
        })
        store(u)
    }

    /** Privacy settings stored on the server (who sees last seen, read receipts...). */
    suspend fun updateSettings(values: Map<String, kotlinx.serialization.json.JsonElement>) {
        val u: User = api!!.send("PATCH", "/me", buildJsonObject { put("settings", kotlinx.serialization.json.JsonObject(values)) })
        store(u)
    }

    suspend fun setFolder(conv: String, folder: String) {
        dao.setFolder(conv, folder)
        runCatching { api?.call("PUT", "/conversations/$conv/prefs", buildJsonObject { put("folder", folder) }) }
    }

    suspend fun searchMessages(q: String): List<MessageEntity> = if (q.length < 2) emptyList() else dao.search(q.lowercase())

    suspend fun removeMember(conv: String, user: String) { api!!.call("DELETE", "/conversations/$conv/members/$user"); deviceCache.remove(conv) }

    suspend fun searchUsers(q: String): List<User> = runCatching { api!!.send<List<User>>("GET", "/users", query = mapOf("q" to q)) }.getOrDefault(emptyList())

    suspend fun refreshConversations() {
        val list = runCatching { api!!.conversations() }.getOrNull() ?: return
        val ids = list.map { it.id.lower }.toSet()
        list.forEach { upsert(it) }
        dao.allConversations().filter { it.id !in ids }.forEach { dao.deleteConversation(it.id) }
    }

    suspend fun refreshConversation(id: String) {
        runCatching { upsert(api!!.conversation(UUID.fromString(id))) }
    }

    private suspend fun upsert(c: Conversation) {
        c.peer?.let { store(it) }
        val id = c.id.lower
        val title = if (c.kind == ConversationKind.dm) c.peer?.displayName ?: c.title else if (c.kind == ConversationKind.saved) "Saved Messages" else c.title
        val payload = AsgardJson.encodeToString(Conversation.serializer(), c)
        val sort = c.lastMessageAt?.toEpochMilli() ?: c.createdAt?.toEpochMilli() ?: 0
        dao.insertIfMissing(ConversationEntity(id = id, payload = payload, kind = c.kind.name, title = title, sortDate = sort))
        dao.updateFromServer(id, payload, c.kind.name, title, sort, c.me?.pinned ?: false, c.me?.archived ?: false, c.me?.folder ?: "",
            c.me?.mutedUntil?.toEpochMilli(), c.communityID?.lower, if (id == activeConversation) 0 else c.unread)
    }

    suspend fun openDM(user: String): String {
        val c: Conversation = api!!.send("POST", "/conversations", buildJsonObject {
            put("kind", "dm"); put("member_ids", kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive(user))))
        })
        upsert(c)
        return c.id.lower
    }

    suspend fun create(kind: ConversationKind, title: String, members: List<String>): String {
        val c: Conversation = api!!.send("POST", "/conversations", buildJsonObject {
            put("kind", kind.name); put("title", title)
            put("member_ids", kotlinx.serialization.json.JsonArray(members.map { JsonPrimitive(it) }))
        })
        upsert(c)
        return c.id.lower
    }

    suspend fun members(conv: String): List<Member> = runCatching { api!!.members(UUID.fromString(conv)) }.getOrDefault(emptyList())

    suspend fun addMembers(conv: String, ids: List<String>) {
        api!!.call("POST", "/conversations/$conv/members", buildJsonObject { put("user_ids", kotlinx.serialization.json.JsonArray(ids.map { JsonPrimitive(it) })) })
        deviceCache.remove(conv)
    }

    suspend fun leave(conv: String) {
        api!!.call("POST", "/conversations/$conv/leave")
        dao.deleteConversation(conv)
        dao.clearMessages(conv)
    }

    suspend fun setPrefs(conv: String, pinned: Boolean? = null, archived: Boolean? = null, mutedUntil: java.time.Instant? = null, unmute: Boolean? = null) {
        dao.conversation(conv)?.let { c ->
            dao.setPrefs(conv, pinned ?: c.pinned, archived ?: c.archived, if (unmute == true) null else mutedUntil?.toEpochMilli() ?: c.mutedUntil)
        }
        runCatching {
            api!!.call("PUT", "/conversations/$conv/prefs", buildJsonObject {
                pinned?.let { put("pinned", it) }; archived?.let { put("archived", it) }
                mutedUntil?.let { put("muted_until", it.toString()) }; unmute?.let { put("unmute", it) }
            })
        }
    }

    suspend fun saveDraft(conv: String, text: String) = dao.setDraft(conv, text)

    suspend fun clearHistory(conv: String) {
        dao.clearMessages(conv)
        dao.clearPreview(conv)
    }

    // endregion

    // region Sync and receiving

    suspend fun syncNow() {
        val api = api ?: return
        if (syncLock.isLocked) return
        syncLock.withLock {
            var more = true
            while (more) {
                val page = runCatching { api.sync(accounts.cursor) }.getOrNull() ?: return
                prefetchSigningKeys(page.envelopes)
                page.envelopes.forEach { process(it, live = false) }
                accounts.cursor = maxOf(accounts.cursor, page.nextCursor)
                more = page.more
            }
        }
    }

    suspend fun loadOlder(conv: String) {
        val api = api ?: return
        val oldest = dao.oldest(conv)?.seq
        val envs = runCatching { api.history(UUID.fromString(conv), oldest) }.getOrNull() ?: return
        prefetchSigningKeys(envs)
        envs.reversed().forEach { process(it, live = false, countUnread = false) }
    }

    /** One-time catch-up of recent history per chat (mirrors iOS repairRecentHistory). */
    private suspend fun repairOnce() {
        val api = api ?: return
        val flag = "repair-v1-$myDeviceID"
        val prefs = context.getSharedPreferences("asgard", Context.MODE_PRIVATE)
        if (prefs.getBoolean(flag, false)) return
        for (c in dao.allConversations().filter { it.kindEnum != ConversationKind.community }) {
            val envs = runCatching { api.history(UUID.fromString(c.id), null, 100) }.getOrNull() ?: continue
            prefetchSigningKeys(envs)
            envs.reversed().forEach { process(it, live = false) }
        }
        prefs.edit().putBoolean(flag, true).apply()
    }

    internal suspend fun prefetchKeys(envs: List<Envelope>) = prefetchSigningKeys(envs)
    internal fun clearDeviceCache() = deviceCache.clear()
    internal fun appPrefs() = context.getSharedPreferences("asgard", Context.MODE_PRIVATE)

    private suspend fun prefetchSigningKeys(envs: List<Envelope>) {
        val missing = envs.filter { e -> e.senderDeviceID != null && !signingKeys.containsKey(e.senderDeviceID.lower) }.mapNotNull { it.senderUserID?.lower }.toSet()
        for (u in missing) runCatching { api!!.devicesOf(UUID.fromString(u)).forEach { signingKeys[it.id.lower] = it.signingKey } }
    }

    private sealed interface Outcome {
        data class System(val sys: JsonElement) : Outcome
        data class Content(val content: MessageContent, val verified: Boolean) : Outcome
        data object Undecryptable : Outcome
    }

    private fun open(env: Envelope, with: com.giantmushroom.asgardchat.crypto.DeviceKeys? = null): Outcome {
        if (env.kind == "system" && env.system != null) return Outcome.System(env.system)
        val keys = with ?: account?.keys ?: return Outcome.Undecryptable
        val ct = env.ciphertext ?: return Outcome.Undecryptable
        val wk = env.wrappedKey ?: return Outcome.Undecryptable
        val dev = env.senderDeviceID ?: return Outcome.Undecryptable
        val aad = E2EE.aad(env.conversationID, dev, env.clientID)
        return try {
            val key = E2EE.unwrap(wk, keys.identityPrivate, env.clientID)
            val content = AsgardJson.decodeFromString(MessageContent.serializer(), String(E2EE.open(ct, key, aad)))
            val verified = signingKeys[dev.lower]?.let { E2EE.verify(it, aad, ct, env.signature ?: ByteArray(0)) } ?: false
            Outcome.Content(content, verified)
        } catch (e: Exception) {
            Outcome.Undecryptable
        }
    }

    /** [openWith] opens with other keys (the history device's) instead of this device's. */
    suspend fun process(env: Envelope, live: Boolean, countUnread: Boolean = true, openWith: com.giantmushroom.asgardchat.crypto.DeviceKeys? = null) {
        if (!live && openWith == null) env.cursor?.let { accounts.cursor = maxOf(accounts.cursor, it) }
        val fromMe = env.senderUserID?.lower == myID
        val conv = env.conversationID.lower
        when (val o = open(env, openWith)) {
            is Outcome.System -> {
                if (dao.message(env.id.lower) != null) return
                dao.upsert(MessageEntity(id = env.id.lower, clientID = env.clientID.lower, conversationID = conv, seq = env.seq, sortKey = env.seq.toDouble(),
                    senderUserID = env.senderUserID?.lower, senderDeviceID = null, sentAt = env.sentAt.toEpochMilli(), status = MessageStatus.received.name,
                    systemJson = o.sys.toString()))
                touchPreview(conv, SystemText.describe(o.sys) { name(it) }, null, env.sentAt.toEpochMilli())
                if (live) refreshConversation(conv)
            }
            Outcome.Undecryptable -> {
                if (env.kind != "msg" || openWith != null) return
                val existing = dao.message(env.id.lower)
                if (existing != null) { if (env.deleted) dao.upsert(deleted(existing)); return }
                dao.upsert(MessageEntity(id = env.id.lower, clientID = env.clientID.lower, conversationID = conv, seq = env.seq, sortKey = env.seq.toDouble(),
                    senderUserID = env.senderUserID?.lower, senderDeviceID = env.senderDeviceID?.lower, sentAt = env.sentAt.toEpochMilli(),
                    status = (if (fromMe) MessageStatus.sent else MessageStatus.received).name, threadRootID = env.threadRootID?.lower,
                    wasDeleted = env.deleted, decryptFailed = !env.deleted, expiresAt = env.expiresAt?.toEpochMilli()))
            }
            is Outcome.Content -> apply(env, o.content, o.verified, live, countUnread)
        }
    }

    private suspend fun apply(env: Envelope, content: MessageContent, verified: Boolean, live: Boolean, countUnread: Boolean) {
        val fromMe = env.senderUserID?.lower == myID
        val conv = env.conversationID.lower
        when (env.kind) {
            "control" -> handleControl(env, content, live)
            "msg" -> {
                if (content.type == "call_key") { content.callKey?.let { callKeys[it.room] = it.key }; return }
                val existing = dao.message(env.id.lower) ?: dao.pending(env.clientID.lower, env.senderDeviceID?.lower)
                var row: MessageEntity
                if (existing != null) {
                    if (existing.id != env.id.lower) dao.deleteMessage(existing.id)
                    row = existing.copy(id = env.id.lower, seq = env.seq, sortKey = env.seq.toDouble(),
                        status = if (existing.statusEnum == MessageStatus.sending || existing.statusEnum == MessageStatus.failed) MessageStatus.sent.name else existing.status)
                } else {
                    row = MessageEntity(id = env.id.lower, clientID = env.clientID.lower, conversationID = conv, seq = env.seq, sortKey = env.seq.toDouble(),
                        senderUserID = env.senderUserID?.lower, senderDeviceID = env.senderDeviceID?.lower, sentAt = env.sentAt.toEpochMilli(),
                        status = (if (fromMe) MessageStatus.sent else MessageStatus.received).name, threadRootID = env.threadRootID?.lower)
                    val c = dao.conversation(conv)
                    if (!fromMe && countUnread && env.threadRootID == null && conv != activeConversation && content.silent != true && c != null &&
                        (live || env.seq > (c.conversation?.me?.readSeq ?: 0))) {
                        dao.incrementUnread(conv)
                    }
                }
                row = row.copy(contentJson = MessageEntity.encodeContent(content), decryptFailed = false, unverified = !verified, expiresAt = env.expiresAt?.toEpochMilli(),
                    viewOnce = env.viewOnce || content.attachments?.any { it.viewOnce == true } == true, searchText = (content.text ?: "").lowercase())
                if (env.deleted) row = deleted(row)
                row = applyPendingOps(row)
                dao.upsert(row)
                if (env.threadRootID == null) touchPreview(conv, preview(content), env.senderUserID?.lower, env.sentAt.toEpochMilli())
                if (existing == null && !fromMe && live && content.silent != true) _incoming.tryEmit(row)
            }
            "edit", "delete", "reaction", "vote", "rsvp", "pin" -> {
                val target = env.targetID?.lower ?: return
                val row = dao.message(target)
                if (row != null) dao.upsert(applyOp(env.kind, content, env.senderUserID?.lower, env.sentAt.toEpochMilli(), row))
                else dao.insert(PendingOpEntity(env.id.lower, target, env.kind, env.senderUserID?.lower, MessageEntity.encodeContent(content), env.sentAt.toEpochMilli()))
            }
        }
    }

    private fun applyOp(kind: String, content: MessageContent?, sender: String?, at: Long, row: MessageEntity): MessageEntity = when (kind) {
        "edit" -> {
            val c = row.content
            if (sender != row.senderUserID || c == null) row
            else row.copy(contentJson = MessageEntity.encodeContent(c.copy(text = content?.text, linkPreviews = content?.linkPreviews)), editedAt = at,
                searchText = (content?.text ?: "").lowercase())
        }
        "delete" -> deleted(row)
        "reaction" -> if (sender == null) row else {
            val r = row.reactions.map { Reaction(it.emoji, it.userIDs.filter { u -> u != sender }) }.filter { it.userIDs.isNotEmpty() }.toMutableList()
            val emoji = content?.emoji
            if (!emoji.isNullOrEmpty()) {
                val i = r.indexOfFirst { it.emoji == emoji }
                if (i >= 0) r[i] = Reaction(emoji, r[i].userIDs + sender) else r += Reaction(emoji, listOf(sender))
            }
            row.copy(reactionsJson = MessageEntity.encodeReactions(r))
        }
        "vote" -> if (sender == null) row else row.copy(votesJson = MessageEntity.encodeVotes(row.votes + (sender to (content?.vote?.optionIDs ?: emptyList()))))
        "rsvp" -> if (sender == null) row else row.copy(rsvpJson = MessageEntity.encodeRsvps(row.rsvps + (sender to (content?.rsvp?.status ?: ""))))
        "pin" -> row.copy(isPinned = content?.pinned ?: true)
        else -> row
    }

    private fun deleted(row: MessageEntity): MessageEntity {
        row.content?.attachments?.forEach { File(mediaDir, it.mediaID.lower).delete() }
        return row.copy(wasDeleted = true, contentJson = null, searchText = "", reactionsJson = null)
    }

    private suspend fun applyPendingOps(row: MessageEntity): MessageEntity {
        var r = row
        for (op in dao.ops(row.id)) {
            val c = op.contentJson?.let { runCatching { AsgardJson.decodeFromString(MessageContent.serializer(), it) }.getOrNull() }
            r = applyOp(op.kind, c, op.senderUserID, op.sentAt, r)
        }
        dao.clearOps(row.id)
        return r
    }

    private suspend fun touchPreview(conv: String, text: String, sender: String?, at: Long) = dao.updatePreview(conv, text, sender, at)

    // endregion

    // region Realtime

    private suspend fun handle(ev: RealtimeEvent) {
        val d = ev.data?.let { runCatching { it.jsonObject }.getOrNull() }
        fun s(k: String) = d?.get(k)?.jsonPrimitive?.contentOrNull
        when (ev.type) {
            "message" -> {
                val env = runCatching { AsgardJson.decodeFromJsonElement(Envelope.serializer(), ev.data!!) }.getOrNull() ?: return
                prefetchSigningKeys(listOf(env))
                process(env, live = true)
                if (env.senderUserID?.lower != myID) realtime?.send("ack", buildJsonObject { put("conversation_id", env.conversationID.lower); put("seq", env.seq) })
            }
            "receipt" -> {
                val conv = s("conversation_id") ?: return
                val user = s("user_id") ?: return
                d?.get("read_seq")?.jsonPrimitive?.longOrNull?.let { seq ->
                    readMarks.update { it + (conv to ((it[conv] ?: emptyMap()) + (user to maxOf(seq, it[conv]?.get(user) ?: 0)))) }
                    if (user == myID) dao.clearUnread(conv)
                }
            }
            "typing" -> {
                val conv = s("conversation_id") ?: return
                val user = s("user_id") ?: return
                if (user == myID) return
                val stop = s("state") == "stop"
                typing.update { all ->
                    val m = (all[conv] ?: emptyMap()).toMutableMap()
                    if (stop) m.remove(user) else m[user] = System.currentTimeMillis() + 6_000
                    all + (conv to m)
                }
            }
            "presence" -> {
                val user = s("user_id") ?: return
                val online = d?.get("online")?.jsonPrimitive?.booleanOrNull ?: false
                presence.update { it + (user to online) }
            }
            "conversation.updated" -> (s("conversation_id") ?: s("id"))?.let { refreshConversation(it) }
            "conversation.removed" -> s("conversation_id")?.let { dao.deleteConversation(it); dao.clearMessages(it) }
            "device.added", "keys.changed" -> deviceCache.clear()
            "user.updated" -> runCatching { store(AsgardJson.decodeFromJsonElement(User.serializer(), ev.data!!)) }
            "call.ring" -> {
                val caller = s("caller_id") ?: return
                if (caller == myID) return
                val call = IncomingCall(UUID.fromString(s("call_id")), UUID.fromString(s("conversation_id")), UUID.fromString(caller),
                    s("caller_name") ?: "Someone", d?.get("video")?.jsonPrimitive?.booleanOrNull ?: false)
                incomingCall.value = call
            }
            "call.ended" -> s("conversation_id")?.let { c ->
                if (incomingCall.value?.conversationID?.lower == c) incomingCall.value = null
                _callEnded.tryEmit(UUID.fromString(c))
            }
            "device.linked" -> shareHistoryKey()
            "voice.state" -> runCatching { AsgardJson.decodeFromJsonElement(VoiceRoomState.serializer(), ev.data!!) }.getOrNull()?.let { st ->
                voiceRooms.update { if (st.participants.isEmpty()) it - st.conversationID.lower else it + (st.conversationID.lower to st.participants) }
            }
        }
    }

    private fun expireTyping() {
        val now = System.currentTimeMillis()
        typing.update { all -> all.mapValues { (_, m) -> m.filterValues { it > now } }.filterValues { it.isNotEmpty() } }
    }

    // endregion

    // region Sending

    suspend fun send(content: MessageContent, conv: String, replyTo: String? = null): MessageEntity {
        val c = if (replyTo != null) content.copy(replyTo = UUID.fromString(replyTo)) else content
        val clientID = UUID.randomUUID().lower
        val lastSeq = maxOf(dao.conversation(conv)?.conversation?.lastSeq ?: 0, dao.maxSeq(conv) ?: 0)
        val now = System.currentTimeMillis()
        val row = MessageEntity(id = clientID, clientID = clientID, conversationID = conv, seq = 0, sortKey = lastSeq + 0.5 + now / 1e15,
            senderUserID = myID, senderDeviceID = myDeviceID, sentAt = now, status = MessageStatus.sending.name,
            contentJson = MessageEntity.encodeContent(c), searchText = (c.text ?: "").lowercase())
        dao.upsert(row)
        touchPreview(conv, preview(c), myID, now)
        saveDraft(conv, "")
        return transmit(row)
    }

    private suspend fun transmit(row: MessageEntity): MessageEntity {
        val content = row.content ?: return row
        return try {
            val env = deliver(content, "msg", row.conversationID, clientID = row.clientID)
            val sent = row.copy(id = env.id.lower, seq = env.seq, sortKey = env.seq.toDouble(), status = MessageStatus.sent.name, error = null)
            if (dao.message(env.id.lower) == null) { dao.deleteMessage(row.id); dao.upsert(sent) } else dao.deleteMessage(row.id)
            sent
        } catch (e: Exception) {
            val failed = row.copy(status = MessageStatus.failed.name, error = (e as? ApiError)?.message ?: e.message)
            dao.upsert(failed)
            failed
        }
    }

    suspend fun retry(row: MessageEntity) { transmit(row.copy(status = MessageStatus.sending.name).also { dao.upsert(it) }) }

    suspend fun deliver(content: MessageContent, kind: String, conv: String, target: String? = null, clientID: String = UUID.randomUUID().lower): Envelope {
        val api = api ?: throw ApiError.offline
        val a = account ?: throw ApiError.offline
        val cid = UUID.fromString(clientID)
        val plaintext = AsgardJson.encodeToString(MessageContent.serializer(), content).toByteArray()
        val aad = E2EE.aad(UUID.fromString(conv), a.deviceID, cid)
        val sealed = E2EE.seal(plaintext, aad)
        val signature = E2EE.sign(a.signingSeed, aad, sealed.ciphertext)
        repeat(3) { attempt ->
            val devices = devicesFor(conv, refresh = attempt > 0)
            val wrapped = devices.associate { it.id.lower to E2EE.wrap(sealed.key, it.identityKey, cid) }
            val req = SendRequest(cid, kind, target?.let(UUID::fromString), null, sealed.ciphertext, signature, keys = wrapped)
            try {
                val raw = api.execute("POST", "/conversations/$conv/messages", AsgardJson.encodeToString(SendRequest.serializer(), req))
                return AsgardJson.decodeFromString(Envelope.serializer(), raw)
            } catch (e: ApiError) {
                if (e.code != "device_mismatch" || attempt == 2) throw e
            }
        }
        throw ApiError(409, "device_mismatch", "Couldn't confirm everyone's devices. Try again.")
    }

    private suspend fun devicesFor(conv: String, refresh: Boolean): List<DeviceInfo> {
        if (!refresh) deviceCache[conv]?.let { return it }
        val d = api!!.devicesIn(UUID.fromString(conv))
        d.forEach { signingKeys[it.id.lower] = it.signingKey }
        deviceCache[conv] = d
        return d
    }

    private suspend fun sendOp(kind: String, content: MessageContent, row: MessageEntity) {
        dao.upsert(applyOp(kind, content, myID, System.currentTimeMillis(), row))
        runCatching { deliver(content, kind, row.conversationID, target = row.id) }.onFailure { banner.value = (it as? ApiError)?.message ?: "Couldn't send." }
    }

    suspend fun react(emoji: String, row: MessageEntity) {
        val mine = row.reactions.firstOrNull { myID in it.userIDs }?.emoji
        sendOp("reaction", MessageContent(type = "reaction", emoji = if (mine == emoji) "" else emoji, target = UUID.fromString(row.id)), row)
    }

    suspend fun edit(row: MessageEntity, text: String) = sendOp("edit", MessageContent(type = "edit", text = text, target = UUID.fromString(row.id)), row)
    suspend fun deleteForEveryone(row: MessageEntity) = sendOp("delete", MessageContent(type = "delete", target = UUID.fromString(row.id)), row)
    suspend fun deleteForMe(row: MessageEntity) = dao.deleteMessage(row.id)
    suspend fun pin(row: MessageEntity, pinned: Boolean) = sendOp("pin", MessageContent(type = "pin", pinned = pinned, target = UUID.fromString(row.id)), row)
    suspend fun vote(options: List<String>, row: MessageEntity) =
        sendOp("vote", MessageContent(type = "vote", vote = MessageContent.Vote(options), target = UUID.fromString(row.id)), row)
    suspend fun rsvp(status: String, row: MessageEntity) =
        sendOp("rsvp", MessageContent(type = "rsvp", rsvp = MessageContent.Rsvp(status), target = UUID.fromString(row.id)), row)
    suspend fun star(row: MessageEntity) = dao.upsert(row.copy(isStarred = !row.isStarred))

    /** Encrypts and uploads files, then sends them as one message. */
    suspend fun sendFiles(files: List<OutgoingFile>, caption: String?, conv: String, type: String = "media", replyTo: String? = null) {
        val api = api ?: return
        try {
            val atts = withContext(Dispatchers.Default) { files.map { it to MediaCrypto.encrypt(it.data) } }.map { (f, enc) ->
                val id = api.upload(enc.blob)
                File(mediaDir, id.lower).writeBytes(f.data)
                MessageContent.Attachment(id, f.mime, f.data.size, f.name, enc.key, enc.digest, f.width, f.height, f.durationMS, f.waveform, f.thumbnail)
            }
            send(MessageContent(type = type, text = caption?.takeIf { it.isNotBlank() }, attachments = atts), conv, replyTo)
        } catch (e: Exception) {
            banner.value = (e as? ApiError)?.message ?: "Couldn't send the file."
        }
    }

    suspend fun attachmentData(a: MessageContent.Attachment): ByteArray {
        val f = File(mediaDir, a.mediaID.lower)
        if (f.exists()) return f.readBytes()
        val blob = api?.download(a.mediaID) ?: throw ApiError.offline
        val data = withContext(Dispatchers.Default) { MediaCrypto.decrypt(blob, a.key, a.digest) }
        f.writeBytes(data)
        return data
    }

    fun markRead(conv: String) {
        scope.launch {
            dao.clearUnread(conv)
            val seq = dao.maxSeq(conv) ?: 0
            if (seq <= 0) return@launch
            if (connection.value == ConnectionState.connected) realtime?.send("read", buildJsonObject { put("conversation_id", conv); put("seq", seq) })
            else runCatching { api?.call("POST", "/conversations/$conv/read", buildJsonObject { put("seq", seq) }) }
        }
    }

    fun setTyping(conv: String) {
        val now = System.currentTimeMillis()
        if (now - (lastTypingSent[conv] ?: 0) < 3_000) return
        lastTypingSent[conv] = now
        realtime?.send("typing", buildJsonObject { put("conversation_id", conv); put("state", "typing") })
    }

    // endregion

    // region Voice rooms and calls (see "Voice rooms" in docs/PROTOCOL.md)

    suspend fun refreshVoiceRooms() {
        val rooms = runCatching { api!!.send<List<VoiceRoomState>>("GET", "/voice") }.getOrNull() ?: return
        voiceRooms.value = rooms.filter { it.participants.isNotEmpty() }.associate { it.conversationID.lower to it.participants }
    }

    suspend fun refreshVoiceRoom(conv: String) {
        val st = runCatching { api!!.send<VoiceRoomState>("GET", "/conversations/$conv/voice") }.getOrNull() ?: return
        voiceRooms.update { if (st.participants.isEmpty()) it - conv else it + (conv to st.participants) }
    }

    suspend fun joinVoice(conv: String, muted: Boolean, video: Boolean): Pair<VoiceJoin, ByteArray?> {
        val join: VoiceJoin = api!!.send("POST", "/conversations/$conv/voice/join", buildJsonObject { put("muted", muted); put("video", video) })
        voiceRooms.update { it + (conv to join.participants) }
        currentVoiceRoom = conv
        if (join.first) {
            val key = E2EE.randomBytes(32)
            callKeys[join.room] = key
            sendCallKey(key, join.room, conv)
            return join to key
        }
        for (attempt in 0 until 40) {
            callKeys[join.room]?.let { return join to it }
            if (attempt % 12 == 0) runCatching {
                deliver(MessageContent(type = "call_key_request", callKey = MessageContent.CallKey(join.room, ByteArray(0))), "control", conv)
            }
            syncNow()
            delay(250)
        }
        return join to null
    }

    suspend fun updateVoice(conv: String, muted: Boolean? = null, video: Boolean? = null) {
        runCatching { api?.call("POST", "/conversations/$conv/voice/update", buildJsonObject { muted?.let { put("muted", it) }; video?.let { put("video", it) } }) }
    }

    suspend fun leaveVoice(conv: String) {
        if (currentVoiceRoom == conv) currentVoiceRoom = null
        runCatching { api?.call("POST", "/conversations/$conv/voice/leave") }
        val me = myDeviceID
        voiceRooms.update { m -> val rest = (m[conv] ?: emptyList()).filter { it.deviceID.lower != me }; if (rest.isEmpty()) m - conv else m + (conv to rest) }
    }

    private suspend fun sendCallKey(key: ByteArray, room: String, conv: String) {
        runCatching { deliver(MessageContent(type = "call_key", callKey = MessageContent.CallKey(room, key)), "control", conv) }
    }

    private fun handleControl(env: Envelope, content: MessageContent, live: Boolean) {
        when (content.type) {
            "call_key" -> content.callKey?.let { callKeys[it.room] = it.key }
            "history_key" -> scope.launch { receivedHistoryKey(content.historyKey, env) }
            "call_key_request" -> {
                val room = content.callKey?.room ?: return
                val conv = currentVoiceRoom ?: return
                if (!live || room != "voice-$conv" || env.senderDeviceID?.lower == myDeviceID) return
                val key = callKeys[room] ?: return
                val others = (voiceRooms.value[conv] ?: emptyList()).filter { it.deviceID != env.senderDeviceID }
                if (others.firstOrNull()?.deviceID?.lower != myDeviceID) return
                scope.launch { sendCallKey(key, room, conv) }
            }
        }
    }

    suspend fun startCall(conv: String, video: Boolean): CallJoin {
        val join: CallJoin = api!!.send("POST", "/conversations/$conv/calls", buildJsonObject { put("video", video) })
        if (!join.joinedExisting) {
            val key = E2EE.randomBytes(32)
            callKeys[join.room] = key
            sendCallKey(key, join.room, conv)
        }
        return join
    }

    suspend fun endCall(conv: String, reason: String, all: Boolean) {
        runCatching { api?.call("POST", "/conversations/$conv/calls/end", buildJsonObject { put("reason", reason); put("all", all) }) }
    }

    suspend fun recordCall(conv: String, video: Boolean, outgoing: Boolean, durationMs: Long, missed: Boolean) {
        dao.upsert(CallEntity(UUID.randomUUID().toString(), conv, System.currentTimeMillis() - durationMs, durationMs, video, outgoing, missed))
    }

    /**
     * Gives the server this phone's push address. Servers that use the Asgard
     * push relay only ever receive an opaque handle, never the FCM token.
     */
    suspend fun registerPush(token: String) {
        val api = api ?: return
        // Always ask: a cached value may belong to a server this phone used before.
        runCatching { api.info() }.getOrNull()?.let { serverInfo.value = it }
        val relay = serverInfo.value?.pushRelay
        val handle = relay?.let { r ->
            runCatching {
                val body = buildJsonObject { put("server_id", r.serverID); put("platform", "fcm"); put("token", token); put("env", "production") }
                val raw = ApiClient(r.url, null).run {
                    val req = okhttp3.Request.Builder().url(r.url.trimEnd('/') + "/v1/devices")
                        .post(body.toString().toRequestBody(ApiClient.jsonType)).build()
                    withContext(Dispatchers.IO) { http.newCall(req).execute().use { if (it.code == 201) it.body.string() else null } }
                }
                raw?.let { Regex("\"handle\"\\s*:\\s*\"([^\"]+)\"").find(it)?.groupValues?.get(1) }
            }.getOrNull()
        }
        val (kind, value) = if (handle != null) "relay" to handle else "fcm" to token
        runCatching { api.call("PUT", "/me/push", buildJsonObject { put("kind", kind); put("token", value); put("voip_token", ""); put("env", "production") }) }
    }

    // endregion

    companion object {
        fun preview(c: MessageContent): String = when (c.type) {
            "text" -> c.text ?: ""
            "media" -> {
                val a = c.attachments ?: emptyList()
                val caption = c.text?.let { " $it" } ?: ""
                when {
                    a.firstOrNull()?.viewOnce == true -> "View once photo"
                    a.isNotEmpty() && a.all { it.mime.startsWith("image/") } -> (if (a.size > 1) "${a.size} photos" else "Photo") + caption
                    a.isNotEmpty() && a.all { it.mime.startsWith("video/") } -> (if (a.size > 1) "${a.size} videos" else "Video") + caption
                    else -> (a.firstOrNull()?.name ?: "File") + caption
                }
            }
            "voice" -> "Voice message"
            "video_note" -> "Video message"
            "location" -> "Location"
            "live_location" -> "Live location"
            "poll" -> "Poll: " + (c.poll?.question ?: "")
            "event" -> "Event: " + (c.event?.title ?: "")
            "sticker" -> "Sticker"
            "gif" -> "GIF"
            "contact" -> "Contact"
            else -> c.text ?: "Message"
        }
    }
}
