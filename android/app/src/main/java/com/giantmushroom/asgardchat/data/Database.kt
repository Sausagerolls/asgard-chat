package com.giantmushroom.asgardchat.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert
import com.giantmushroom.asgardchat.net.AsgardJson
import com.giantmushroom.asgardchat.net.Conversation
import com.giantmushroom.asgardchat.net.ConversationKind
import com.giantmushroom.asgardchat.net.MessageContent
import com.giantmushroom.asgardchat.net.User
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer

enum class MessageStatus { sending, sent, delivered, read, failed, received }

@Entity(tableName = "conversations")
data class ConversationEntity(
    @PrimaryKey val id: String,
    val payload: String,
    val kind: String,
    val title: String,
    val sortDate: Long,
    val pinned: Boolean = false,
    val archived: Boolean = false,
    val unread: Int = 0,
    val folder: String = "",
    val mutedUntil: Long? = null,
    val previewText: String = "",
    val previewSenderID: String? = null,
    val previewDate: Long? = null,
    val draft: String = "",
    val communityID: String? = null,
    val markedUnread: Boolean = false,
) {
    val conversation: Conversation? get() = runCatching { AsgardJson.decodeFromString(Conversation.serializer(), payload) }.getOrNull()
    val kindEnum: ConversationKind get() = runCatching { ConversationKind.valueOf(kind) }.getOrDefault(ConversationKind.group)
    val isMuted: Boolean get() = (mutedUntil ?: 0) > System.currentTimeMillis()
}

@Serializable data class Reaction(val emoji: String, val userIDs: List<String>)

@Entity(tableName = "messages", indices = [Index("conversationID"), Index("clientID"), Index("sortKey")])
data class MessageEntity(
    @PrimaryKey val id: String,
    val clientID: String,
    val conversationID: String,
    val seq: Long,
    val sortKey: Double,
    val senderUserID: String?,
    val senderDeviceID: String?,
    val sentAt: Long,
    val expiresAt: Long? = null,
    val status: String,
    val contentJson: String? = null,
    val systemJson: String? = null,
    val threadRootID: String? = null,
    val replyCount: Int = 0,
    val wasDeleted: Boolean = false,
    val editedAt: Long? = null,
    val reactionsJson: String? = null,
    val votesJson: String? = null,
    val rsvpJson: String? = null,
    val isPinned: Boolean = false,
    val isStarred: Boolean = false,
    val decryptFailed: Boolean = false,
    val unverified: Boolean = false,
    val viewOnce: Boolean = false,
    val searchText: String = "",
    val error: String? = null,
) {
    val content: MessageContent? get() = contentJson?.let { runCatching { AsgardJson.decodeFromString(MessageContent.serializer(), it) }.getOrNull() }
    val isSystem: Boolean get() = systemJson != null
    val statusEnum: MessageStatus get() = runCatching { MessageStatus.valueOf(status) }.getOrDefault(MessageStatus.sent)
    val reactions: List<Reaction> get() = reactionsJson?.let { runCatching { AsgardJson.decodeFromString(ListSerializer(Reaction.serializer()), it) }.getOrNull() } ?: emptyList()
    val votes: Map<String, List<String>> get() = votesJson?.let { runCatching { AsgardJson.decodeFromString(MapSerializer(String.serializer(), ListSerializer(String.serializer())), it) }.getOrNull() } ?: emptyMap()
    val rsvps: Map<String, String> get() = rsvpJson?.let { runCatching { AsgardJson.decodeFromString(MapSerializer(String.serializer(), String.serializer()), it) }.getOrNull() } ?: emptyMap()

    companion object {
        fun encodeReactions(r: List<Reaction>) = AsgardJson.encodeToString(ListSerializer(Reaction.serializer()), r)
        fun encodeVotes(v: Map<String, List<String>>) = AsgardJson.encodeToString(MapSerializer(String.serializer(), ListSerializer(String.serializer())), v)
        fun encodeRsvps(v: Map<String, String>) = AsgardJson.encodeToString(MapSerializer(String.serializer(), String.serializer()), v)
        fun encodeContent(c: MessageContent) = AsgardJson.encodeToString(MessageContent.serializer(), c)
    }
}

@Entity(tableName = "users")
data class UserEntity(@PrimaryKey val id: String, val payload: String, val displayName: String, val username: String) {
    val user: User? get() = runCatching { AsgardJson.decodeFromString(User.serializer(), payload) }.getOrNull()
}

/** Edits/reactions that arrived before their target message. */
@Entity(tableName = "pending_ops", indices = [Index("targetID")])
data class PendingOpEntity(@PrimaryKey val id: String, val targetID: String, val kind: String, val senderUserID: String?, val contentJson: String?, val sentAt: Long)

@Entity(tableName = "calls")
data class CallEntity(@PrimaryKey val id: String, val conversationID: String, val startedAt: Long, val duration: Long, val video: Boolean, val outgoing: Boolean, val missed: Boolean)

@Dao
interface ChatDao {
    @Query("SELECT * FROM conversations ORDER BY pinned DESC, sortDate DESC") fun conversations(): Flow<List<ConversationEntity>>
    @Query("SELECT * FROM conversations") suspend fun allConversations(): List<ConversationEntity>
    @Query("SELECT * FROM conversations WHERE id = :id") suspend fun conversation(id: String): ConversationEntity?
    @Query("SELECT * FROM conversations WHERE id = :id") fun conversationFlow(id: String): Flow<ConversationEntity?>
    @Upsert suspend fun upsert(c: ConversationEntity)
    @Query("DELETE FROM conversations WHERE id = :id") suspend fun deleteConversation(id: String)

    // Column-level updates: several coroutines touch the same row, so never read-modify-write the whole row.
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun insertIfMissing(c: ConversationEntity)
    @Query("""UPDATE conversations SET payload = :payload, kind = :kind, title = :title, sortDate = MAX(sortDate, :sortDate), pinned = :pinned,
        archived = :archived, folder = :folder, mutedUntil = :mutedUntil, communityID = :communityID, unread = :unread WHERE id = :id""")
    suspend fun updateFromServer(id: String, payload: String, kind: String, title: String, sortDate: Long, pinned: Boolean, archived: Boolean,
                                 folder: String, mutedUntil: Long?, communityID: String?, unread: Int)
    @Query("""UPDATE conversations SET previewText = :text, previewSenderID = :sender, previewDate = :at, sortDate = MAX(sortDate, :at)
        WHERE id = :id AND (previewDate IS NULL OR previewDate <= :at)""")
    suspend fun updatePreview(id: String, text: String, sender: String?, at: Long)
    @Query("UPDATE conversations SET unread = unread + 1 WHERE id = :id") suspend fun incrementUnread(id: String)
    @Query("UPDATE conversations SET unread = 0, markedUnread = 0 WHERE id = :id") suspend fun clearUnread(id: String)
    @Query("UPDATE conversations SET draft = :draft WHERE id = :id") suspend fun setDraft(id: String, draft: String)
    @Query("UPDATE conversations SET pinned = :pinned, archived = :archived, mutedUntil = :mutedUntil WHERE id = :id")
    suspend fun setPrefs(id: String, pinned: Boolean, archived: Boolean, mutedUntil: Long?)
    @Query("UPDATE conversations SET previewText = '', previewSenderID = NULL WHERE id = :id") suspend fun clearPreview(id: String)
    @Query("UPDATE conversations SET folder = :folder WHERE id = :id") suspend fun setFolder(id: String, folder: String)
    @Query("SELECT COUNT(*) FROM messages") suspend fun messageCount(): Int
    @Query("SELECT * FROM messages WHERE isStarred = 1 ORDER BY sentAt DESC") fun starred(): Flow<List<MessageEntity>>

    @Query("SELECT * FROM messages WHERE conversationID = :conv AND threadRootID IS NULL ORDER BY sortKey") fun messages(conv: String): Flow<List<MessageEntity>>
    @Query("SELECT * FROM messages WHERE id = :id") suspend fun message(id: String): MessageEntity?
    @Query("SELECT * FROM messages WHERE clientID = :clientID AND (senderDeviceID = :device OR :device IS NULL) AND seq = 0 LIMIT 1")
    suspend fun pending(clientID: String, device: String?): MessageEntity?
    @Query("SELECT * FROM messages WHERE conversationID = :conv AND seq > 0 ORDER BY seq ASC LIMIT 1") suspend fun oldest(conv: String): MessageEntity?
    @Query("SELECT MAX(seq) FROM messages WHERE conversationID = :conv") suspend fun maxSeq(conv: String): Long?
    @Query("SELECT * FROM messages WHERE searchText LIKE '%' || :q || '%' ORDER BY sentAt DESC LIMIT 50") suspend fun search(q: String): List<MessageEntity>
    @Upsert suspend fun upsert(m: MessageEntity)
    @Query("DELETE FROM messages WHERE id = :id") suspend fun deleteMessage(id: String)
    @Query("DELETE FROM messages WHERE conversationID = :conv") suspend fun clearMessages(conv: String)
    @Query("DELETE FROM messages WHERE expiresAt IS NOT NULL AND expiresAt < :now") suspend fun purgeExpired(now: Long)

    @Query("SELECT * FROM users WHERE id = :id") suspend fun user(id: String): UserEntity?
    @Query("SELECT * FROM users") fun usersFlow(): Flow<List<UserEntity>>
    @Upsert suspend fun upsert(u: UserEntity)

    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun insert(op: PendingOpEntity)
    @Query("SELECT * FROM pending_ops WHERE targetID = :target ORDER BY sentAt") suspend fun ops(target: String): List<PendingOpEntity>
    @Query("DELETE FROM pending_ops WHERE targetID = :target") suspend fun clearOps(target: String)

    @Upsert suspend fun upsert(c: CallEntity)
    @Query("SELECT * FROM calls ORDER BY startedAt DESC") fun calls(): Flow<List<CallEntity>>
    @Query("DELETE FROM calls WHERE id = :id") suspend fun deleteCall(id: String)
}

@Database(entities = [ConversationEntity::class, MessageEntity::class, UserEntity::class, PendingOpEntity::class, CallEntity::class], version = 1)
abstract class AsgardDatabase : RoomDatabase() {
    abstract fun dao(): ChatDao

    companion object {
        fun open(context: Context): AsgardDatabase =
            Room.databaseBuilder(context, AsgardDatabase::class.java, "asgard.db").fallbackToDestructiveMigration(true).build()
    }
}
