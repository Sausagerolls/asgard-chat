package com.giantmushroom.asgardchat.engine

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Human text for plaintext system envelopes (membership, title changes...). */
object SystemText {
    fun describe(sys: JsonElement, name: (String?) -> String): String {
        val o = sys as? JsonObject ?: return "Chat updated"
        fun str(k: String, from: JsonObject = o) = from[k]?.jsonPrimitive?.contentOrNull
        val actor = name(str("actor_id"))
        val subject = name(str("user_id"))
        return when (str("event")) {
            "created" -> "$actor created \"${str("title") ?: "this chat"}\""
            "joined" -> "$actor joined"
            "left" -> "$actor left"
            "members_added" -> {
                val ids = o["user_ids"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList()
                if (ids.size <= 3) "$actor added ${ids.joinToString(", ") { name(it) }}" else "$actor added ${ids.size} people"
            }
            "member_removed" -> "$actor removed $subject"
            "member_updated" -> "$actor made $subject ${str("role") ?: "a member"}"
            "webhook_added" -> "$actor added the webhook \"${str("name") ?: ""}\""
            "updated" -> {
                val c = o["changes"]?.jsonObject
                when {
                    c == null -> "$actor updated the chat"
                    c["title"] != null -> "$actor renamed the chat to \"${str("title", c)}\""
                    c["disappearing_seconds"] != null -> {
                        val s = c["disappearing_seconds"]!!.jsonPrimitive.doubleOrNull ?: 0.0
                        if (s == 0.0) "$actor turned off disappearing messages" else "$actor set messages to disappear"
                    }
                    c["avatar_media_id"] != null -> "$actor changed the chat photo"
                    c["description"] != null -> "$actor changed the description"
                    c["slow_mode_seconds"] != null -> "$actor changed slow mode"
                    else -> "$actor updated the chat"
                }
            }
            else -> "Chat updated"
        }
    }
}
