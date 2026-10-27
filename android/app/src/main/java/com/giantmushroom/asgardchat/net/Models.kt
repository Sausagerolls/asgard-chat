package com.giantmushroom.asgardchat.net

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import java.time.Instant
import java.time.OffsetDateTime
import java.util.Base64
import java.util.UUID

// Wire types for the Asgard REST API (docs/PROTOCOL.md), mirroring AsgardKit's APIModels.swift.

val AsgardJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
}

object UUIDSerializer : KSerializer<UUID> {
    override val descriptor = PrimitiveSerialDescriptor("UUID", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: UUID) = encoder.encodeString(value.toString().lowercase())
    override fun deserialize(decoder: Decoder): UUID = UUID.fromString(decoder.decodeString())
}

object Base64Serializer : KSerializer<ByteArray> {
    override val descriptor = PrimitiveSerialDescriptor("Base64", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ByteArray) = encoder.encodeString(Base64.getEncoder().encodeToString(value))
    override fun deserialize(decoder: Decoder): ByteArray = Base64.getDecoder().decode(decoder.decodeString())
}

/** RFC 3339 timestamps from the server. */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(value.toString())
    override fun deserialize(decoder: Decoder): Instant {
        val s = decoder.decodeString()
        return runCatching { Instant.parse(s) }.getOrElse { OffsetDateTime.parse(s).toInstant() }
    }
}

/** Dates inside encrypted content use Swift's default: seconds since 2001-01-01. */
object AppleDateSerializer : KSerializer<Instant> {
    private const val EPOCH_2001 = 978_307_200.0
    override val descriptor = PrimitiveSerialDescriptor("AppleDate", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeDouble(value.epochSecond + value.nano / 1e9 - EPOCH_2001)
    override fun deserialize(decoder: Decoder): Instant {
        val s = decoder.decodeDouble() + EPOCH_2001
        return Instant.ofEpochSecond(s.toLong(), ((s - s.toLong()) * 1e9).toLong())
    }
}

typealias Id = @Serializable(UUIDSerializer::class) UUID
typealias Bytes = @Serializable(Base64Serializer::class) ByteArray
typealias Time = @Serializable(InstantSerializer::class) Instant

@Serializable
data class User(
    val id: Id,
    val username: String,
    @SerialName("display_name") val displayName: String,
    val bio: String = "",
    @SerialName("avatar_media_id") val avatarMediaID: Id? = null,
    @SerialName("is_admin") val isAdmin: Boolean = false,
    @SerialName("is_bot") val isBot: Boolean = false,
    @SerialName("server_bot") val serverBot: Boolean = false,
    val online: Boolean = false,
    @SerialName("last_seen_at") val lastSeenAt: Time? = null,
    val settings: Map<String, JsonElement>? = null,
)

@Serializable
data class DeviceInfo(
    val id: Id,
    @SerialName("user_id") val userID: Id,
    val name: String? = null,
    val platform: String? = null,
    @SerialName("identity_key") val identityKey: Bytes,
    @SerialName("signing_key") val signingKey: Bytes,
    @SerialName("created_at") val createdAt: Time? = null,
    @SerialName("last_active_at") val lastActiveAt: Time? = null,
    val current: Boolean? = null,
)

@Serializable
data class DeviceRegistration(
    val name: String,
    val platform: String,
    @SerialName("identity_key") val identityKey: Bytes,
    @SerialName("signing_key") val signingKey: Bytes,
)

@Serializable
data class Session(val token: String, val user: User, @SerialName("device_id") val deviceID: Id)

@Serializable
data class ServerInfo(
    val name: String,
    val version: String,
    val features: Features = Features(),
    @SerialName("max_upload_bytes") val maxUploadBytes: Long = 0,
    @SerialName("livekit_url") val livekitURL: String = "",
    @SerialName("push_relay") val pushRelay: PushRelay? = null,
) {
    @Serializable
    data class PushRelay(val url: String, @SerialName("server_id") val serverID: String)

    @Serializable
    data class Features(
        val calls: Boolean = false,
        val push: Boolean = false,
        val media: Boolean = false,
        @SerialName("voice_rooms") val voiceRooms: Boolean = false,
    )
}

enum class ConversationKind { dm, group, channel, community, saved;
    val hasVoiceRoom get() = this == group || this == channel
}

enum class MemberRole { subscriber, member, moderator, admin, owner }

@Serializable
data class MyMembership(
    val role: MemberRole = MemberRole.member,
    val permissions: Long = 0,
    @SerialName("muted_until") val mutedUntil: Time? = null,
    val pinned: Boolean = false,
    val archived: Boolean = false,
    val folder: String = "",
    @SerialName("read_seq") val readSeq: Long = 0,
)

@Serializable
data class Conversation(
    val id: Id,
    val kind: ConversationKind,
    @SerialName("community_id") val communityID: Id? = null,
    val title: String = "",
    val description: String = "",
    @SerialName("avatar_media_id") val avatarMediaID: Id? = null,
    @SerialName("created_at") val createdAt: Time? = null,
    @SerialName("last_seq") val lastSeq: Long = 0,
    @SerialName("last_message_at") val lastMessageAt: Time? = null,
    @SerialName("disappearing_seconds") val disappearingSeconds: Int = 0,
    @SerialName("member_count") val memberCount: Int = 0,
    @SerialName("has_server_bot") val hasServerBot: Boolean = false,
    val unread: Int = 0,
    val me: MyMembership? = null,
    val peer: User? = null,
)

@Serializable
data class Member(val user: User, val role: MemberRole = MemberRole.member, @SerialName("read_seq") val readSeq: Long = 0)

@Serializable
data class Envelope(
    val id: Id,
    @SerialName("conversation_id") val conversationID: Id,
    val seq: Long,
    @SerialName("client_id") val clientID: Id,
    val kind: String,
    @SerialName("target_id") val targetID: Id? = null,
    @SerialName("thread_root_id") val threadRootID: Id? = null,
    @SerialName("sender_user_id") val senderUserID: Id? = null,
    @SerialName("sender_device_id") val senderDeviceID: Id? = null,
    val alg: String = "fanout-v1",
    val ciphertext: Bytes? = null,
    val signature: Bytes? = null,
    val system: JsonElement? = null,
    @SerialName("wrapped_key") val wrappedKey: Bytes? = null,
    @SerialName("sent_at") val sentAt: Time,
    @SerialName("expires_at") val expiresAt: Time? = null,
    @SerialName("view_once") val viewOnce: Boolean = false,
    val deleted: Boolean = false,
    val cursor: Long? = null,
)

@Serializable
data class SyncPage(val envelopes: List<Envelope> = emptyList(), @SerialName("next_cursor") val nextCursor: Long = 0, val more: Boolean = false)

@Serializable
data class SendRequest(
    @SerialName("client_id") val clientID: Id,
    val kind: String,
    @SerialName("target_id") val targetID: Id? = null,
    @SerialName("thread_root_id") val threadRootID: Id? = null,
    val ciphertext: Bytes,
    val signature: Bytes,
    val alg: String = "fanout-v1",
    val keys: Map<String, Bytes>,
    @SerialName("expires_in") val expiresIn: Int? = null,
    @SerialName("view_once") val viewOnce: Boolean = false,
)

@Serializable
data class VoiceParticipant(
    @SerialName("user_id") val userID: Id,
    @SerialName("device_id") val deviceID: Id,
    val name: String,
    val muted: Boolean = false,
    val video: Boolean = false,
    @SerialName("joined_at") val joinedAt: Time,
)

@Serializable
data class VoiceRoomState(@SerialName("conversation_id") val conversationID: Id, val room: String, val participants: List<VoiceParticipant> = emptyList())

@Serializable
data class VoiceJoin(val url: String, val token: String, val room: String, val first: Boolean, val participants: List<VoiceParticipant> = emptyList())

@Serializable
data class CallJoin(val url: String, val token: String, val room: String, @SerialName("joined_existing") val joinedExisting: Boolean = false)

/** The decrypted body of a message (content_json in docs/PROTOCOL.md). */
@Serializable
data class MessageContent(
    val v: Int = 1,
    val type: String,
    val text: String? = null,
    @SerialName("reply_to") val replyTo: Id? = null,
    val target: Id? = null,
    val emoji: String? = null,
    val attachments: List<Attachment>? = null,
    val poll: Poll? = null,
    val vote: Vote? = null,
    val event: Event? = null,
    val rsvp: Rsvp? = null,
    val location: Location? = null,
    @SerialName("link_previews") val linkPreviews: List<LinkPreview>? = null,
    @SerialName("call_key") val callKey: CallKey? = null,
    @SerialName("history_key") val historyKey: Bytes? = null,
    val forwarded: Boolean? = null,
    val silent: Boolean? = null,
    val pinned: Boolean? = null,
) {
    @Serializable
    data class Attachment(
        @SerialName("media_id") val mediaID: Id,
        val mime: String,
        val size: Int,
        val name: String? = null,
        val key: Bytes,
        val digest: Bytes,
        val width: Int? = null,
        val height: Int? = null,
        @SerialName("duration_ms") val durationMS: Int? = null,
        val waveform: Bytes? = null,
        val thumbnail: Bytes? = null,
        @SerialName("view_once") val viewOnce: Boolean? = null,
    )

    @Serializable data class Poll(val question: String, val options: List<Option>, val multiple: Boolean = false) {
        @Serializable data class Option(val id: String, val text: String)
    }
    @Serializable data class Vote(@SerialName("option_ids") val optionIDs: List<String>)
    @Serializable data class Event(
        val title: String,
        @SerialName("starts_at") @Serializable(AppleDateSerializer::class) val startsAt: Instant,
        val location: String? = null,
    )
    @Serializable data class Rsvp(val status: String)
    @Serializable data class Location(val lat: Double, val lon: Double, val name: String? = null)
    @Serializable data class LinkPreview(val url: String, val title: String? = null, val description: String? = null)
    @Serializable data class CallKey(val room: String, val key: Bytes)

    companion object {
        fun text(s: String, replyTo: UUID? = null) = MessageContent(type = "text", text = s, replyTo = replyTo)
    }
}

@Serializable data class ApiErrorBody(val error: Detail) {
    @Serializable data class Detail(val code: String, val message: String)
}
