package com.giantmushroom.asgardchat.notify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.BuildConfig
import com.giantmushroom.asgardchat.MainActivity
import com.giantmushroom.asgardchat.R

/**
 * Keeps the encrypted connection to your server open while the app is in the
 * background, for phones without Firebase push. Android requires a small
 * permanent notification for this; you can hide it in system settings.
 */
class ConnectionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val sys = getSystemService(NotificationManager::class.java)
        sys.createNotificationChannel(NotificationChannel(CHANNEL, "Background connection", NotificationManager.IMPORTANCE_MIN).apply { setShowBadge(false) })
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle("Connected to your Asgard server").setContentText("Keeps messages arriving while the app is closed.")
            .setContentIntent(open).setOngoing(true).setPriority(NotificationCompat.PRIORITY_MIN).build()
        ServiceCompat.startForeground(this, 1, n, if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING else 0)
        AsgardApp.engine.foreground()
        return START_STICKY
    }

    companion object {
        private const val CHANNEL = "connection"
        fun prefs(context: Context) = context.getSharedPreferences("asgard", Context.MODE_PRIVATE)
        /** On by default when there's no Firebase push. */
        fun enabled(context: Context) = prefs(context).getBoolean("backgroundConnection", !BuildConfig.HAS_FIREBASE)
        fun setEnabled(context: Context, on: Boolean) { prefs(context).edit().putBoolean("backgroundConnection", on).apply(); sync(context) }
        fun sync(context: Context) {
            val i = Intent(context, ConnectionService::class.java)
            if (enabled(context) && AsgardApp.engine.account != null) runCatching { ContextCompat.startForegroundService(context, i) } else context.stopService(i)
        }
    }
}

/** Keeps microphone and camera running during a call while the app is in the background. */
class CallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra("title") ?: "Call"
        val video = intent?.getBooleanExtra("video", false) == true
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, Notifier.ONGOING).setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(title).setContentText("End-to-end encrypted").setUsesChronometer(true).setWhen(System.currentTimeMillis())
            .setCategory(NotificationCompat.CATEGORY_CALL).setContentIntent(open).setOngoing(true).build()
        var type = 0
        if (Build.VERSION.SDK_INT >= 30) {
            type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (video) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        runCatching { ServiceCompat.startForeground(this, 2, n, type) }
        return START_NOT_STICKY
    }

    companion object {
        fun start(context: Context, title: String, video: Boolean) = runCatching {
            ContextCompat.startForegroundService(context, Intent(context, CallService::class.java).putExtra("title", title).putExtra("video", video))
        }
        fun stop(context: Context) = context.stopService(Intent(context, CallService::class.java))
    }
}
