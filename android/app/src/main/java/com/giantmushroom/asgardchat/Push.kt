package com.giantmushroom.asgardchat

import android.content.Context
import com.giantmushroom.asgardchat.net.AsgardJson
import com.giantmushroom.asgardchat.net.Envelope
import com.giantmushroom.asgardchat.engine.IncomingCall
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.util.UUID

/**
 * Firebase push, using the Firebase project in app/google-services.json (your
 * own). Pushes carry only ciphertext; the phone decrypts and notifies.
 */
object Push {
    fun register(context: Context) {
        if (!BuildConfig.HAS_FIREBASE) return
        runCatching {
            FirebaseMessaging.getInstance().token.addOnSuccessListener { t -> AsgardApp.engine.scope.launch { AsgardApp.engine.registerPush(t) } }
        }
    }
}

class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        AsgardApp.engine.scope.launch { AsgardApp.engine.registerPush(token) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val engine = AsgardApp.engine
        val d = message.data
        // Runs on a worker thread; finish the work before Android stops the service.
        runBlocking {
            when (d["kind"]) {
                "call" -> {
                    val call = IncomingCall(UUID.fromString(d["call_id"]), UUID.fromString(d["conversation_id"]), UUID.fromString(d["caller_id"]),
                        d["caller_name"] ?: "Someone", d["video"] == "true")
                    engine.incomingCall.value = call
                    AsgardApp.notifier.incomingCall(call)
                }
                "sync" -> engine.syncNow()
                else -> {
                    val env = d["e"]?.let { runCatching { AsgardJson.decodeFromString(Envelope.serializer(), it) }.getOrNull() }
                    if (env != null) engine.process(env, live = true) else {
                        engine.syncNow()
                        d["m"]?.let { engine.dao.message(it) }?.let { AsgardApp.notifier.messageArrived(it) }
                    }
                }
            }
        }
    }
}
