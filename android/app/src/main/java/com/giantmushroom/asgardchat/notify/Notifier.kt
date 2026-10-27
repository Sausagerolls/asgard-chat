package com.giantmushroom.asgardchat.notify

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.MainActivity
import com.giantmushroom.asgardchat.R
import com.giantmushroom.asgardchat.data.MessageEntity
import com.giantmushroom.asgardchat.engine.ChatEngine
import com.giantmushroom.asgardchat.engine.IncomingCall
import com.giantmushroom.asgardchat.net.ConversationKind
import com.giantmushroom.asgardchat.net.MessageContent
import com.giantmushroom.asgardchat.ui.calls.ActiveCall
import kotlinx.coroutines.launch

/**
 * Conversation notifications. MessagingStyle with reply and mark-as-read
 * actions is also exactly what Android Auto reads aloud and replies through.
 */
class Notifier(private val context: Context) {
    private val nm = NotificationManagerCompat.from(context)
    /** Recent lines per conversation, so a notification shows the thread. */
    private val history = mutableMapOf<String, MutableList<NotificationCompat.MessagingStyle.Message>>()

    init {
        val sys = context.getSystemService(NotificationManager::class.java)
        sys.createNotificationChannel(NotificationChannel(MESSAGES, "Messages", NotificationManager.IMPORTANCE_HIGH))
        sys.createNotificationChannel(NotificationChannel(CALLS, "Incoming calls", NotificationManager.IMPORTANCE_HIGH))
        sys.createNotificationChannel(NotificationChannel(ONGOING, "Ongoing calls", NotificationManager.IMPORTANCE_LOW))
    }

    private fun allowed() = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun openIntent(conv: String) = PendingIntent.getActivity(context, conv.hashCode(),
        Intent(context, MainActivity::class.java).putExtra(MainActivity.EXTRA_CONVERSATION, conv).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun messageArrived(row: MessageEntity) {
        val engine = AsgardApp.engine
        if (AsgardApp.foreground && engine.activeConversation == row.conversationID) return
        if (AsgardApp.foreground && !AsgardApp.prefs.inAppBanners) return
        engine.scope.launch {
            val conv = engine.dao.conversation(row.conversationID) ?: return@launch
            if (conv.isMuted) return@launch
            val text = if (AsgardApp.prefs.notificationPreview) row.content?.let { ChatEngine.preview(it) } ?: "New message" else "New message"
            val sender = Person.Builder().setName(engine.name(row.senderUserID)).setKey(row.senderUserID).build()
            history.getOrPut(conv.id) { mutableListOf() }.apply { add(NotificationCompat.MessagingStyle.Message(text, row.sentAt, sender)); while (size > 8) removeAt(0) }
            post(conv.id, conv.title, conv.kindEnum != ConversationKind.dm)
        }
    }

    private fun post(conv: String, title: String, group: Boolean) {
        if (!allowed()) return
        val me = Person.Builder().setName("You").setKey(AsgardApp.engine.myID ?: "me").build()
        val style = NotificationCompat.MessagingStyle(me).setGroupConversation(group).setConversationTitle(if (group) title else null)
        history[conv]?.forEach { style.addMessage(it) }

        ShortcutManagerCompat.pushDynamicShortcut(context, ShortcutInfoCompat.Builder(context, conv).setShortLabel(title).setLongLived(true)
            .setIcon(IconCompat.createWithResource(context, R.drawable.brand_mark)).setPerson(Person.Builder().setName(title).build())
            .setIntent(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).putExtra(MainActivity.EXTRA_CONVERSATION, conv)).build())

        val reply = NotificationCompat.Action.Builder(R.drawable.brand_mark, "Reply",
            PendingIntent.getBroadcast(context, conv.hashCode(), Intent(context, ActionReceiver::class.java).setAction(ACTION_REPLY).putExtra(EXTRA_CONV, conv),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE))
            .addRemoteInput(RemoteInput.Builder(KEY_REPLY).setLabel("Message").build())
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY).setShowsUserInterface(false).build()
        val read = NotificationCompat.Action.Builder(R.drawable.brand_mark, "Mark as read",
            PendingIntent.getBroadcast(context, conv.hashCode() + 1, Intent(context, ActionReceiver::class.java).setAction(ACTION_READ).putExtra(EXTRA_CONV, conv),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ).setShowsUserInterface(false).build()

        nm.notify(conv.hashCode(), NotificationCompat.Builder(context, MESSAGES)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setStyle(style).setShortcutId(conv).setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setContentIntent(openIntent(conv)).setAutoCancel(true)
            .setSilent(!AsgardApp.prefs.notificationSound)
            .addAction(reply).addAction(read).build())
    }

    fun clear(conv: String) { history.remove(conv); nm.cancel(conv.hashCode()) }

    fun incomingCall(c: IncomingCall) {
        if (!allowed()) return
        val full = PendingIntent.getActivity(context, 7, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        nm.notify(CALL_ID, NotificationCompat.Builder(context, CALLS).setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(c.callerName).setContentText(if (c.video) "Incoming video call" else "Incoming call")
            .setCategory(NotificationCompat.CATEGORY_CALL).setPriority(NotificationCompat.PRIORITY_MAX)
            .setFullScreenIntent(full, true).setContentIntent(full).setOngoing(true).setTimeoutAfter(45_000).build())
    }

    fun ongoingCall(call: ActiveCall) {
        if (!allowed()) return
        nm.notify(CALL_ID, NotificationCompat.Builder(context, ONGOING).setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(call.title).setContentText(if (call.voiceRoom) "In voice room · end-to-end encrypted" else "Call in progress · end-to-end encrypted")
            .setOngoing(true).setUsesChronometer(true).setWhen(System.currentTimeMillis()).setContentIntent(openIntent(call.conversationID)).build())
    }

    fun cancelCall() = nm.cancel(CALL_ID)

    companion object {
        const val MESSAGES = "messages"; const val CALLS = "calls"; const val ONGOING = "ongoing"
        const val ACTION_REPLY = "com.giantmushroom.asgardchat.REPLY"; const val ACTION_READ = "com.giantmushroom.asgardchat.READ"
        const val EXTRA_CONV = "conv"; const val KEY_REPLY = "reply"; private const val CALL_ID = 4242
    }
}

/** Handles Reply and Mark as read from notifications (phone and Android Auto). */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val conv = intent.getStringExtra(Notifier.EXTRA_CONV) ?: return
        val engine = AsgardApp.engine
        val pending = goAsync()
        engine.scope.launch {
            try {
                when (intent.action) {
                    Notifier.ACTION_REPLY -> {
                        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(Notifier.KEY_REPLY)?.toString()
                        if (!text.isNullOrBlank()) engine.send(MessageContent.text(text), conv)
                        engine.markRead(conv)
                    }
                    Notifier.ACTION_READ -> engine.markRead(conv)
                }
                AsgardApp.notifier.clear(conv)
            } finally { pending.finish() }
        }
    }
}
