package com.giantmushroom.asgardchat

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.giantmushroom.asgardchat.engine.ChatEngine
import com.giantmushroom.asgardchat.notify.Notifier
import com.giantmushroom.asgardchat.ui.theme.Appearance
import kotlinx.coroutines.launch

class AsgardApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        // Loads WebRTC's native library, needed before any call or voice room key is set up.
        runCatching { io.livekit.android.LiveKit.init(this) }
        engine = ChatEngine(this)
        appearance = Appearance(this)
        prefs = com.giantmushroom.asgardchat.data.Prefs(this)
        notifier = Notifier(this)
        engine.start()
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) { foreground = true; engine.foreground() }
            override fun onStop(owner: LifecycleOwner) { foreground = false }
        })
        engine.scope.launch { engine.incomingMessages.collect { notifier.messageArrived(it) } }
        engine.scope.launch {
            engine.phase.collect {
                com.giantmushroom.asgardchat.notify.ConnectionService.sync(this@AsgardApp)
                if (it == com.giantmushroom.asgardchat.engine.Phase.Ready) Push.register(this@AsgardApp)
            }
        }
        engine.scope.launch { engine.incomingCall.collect { c -> if (c != null && !foreground) notifier.incomingCall(c) } }
    }

    companion object {
        lateinit var instance: AsgardApp; private set
        lateinit var engine: ChatEngine; private set
        lateinit var appearance: Appearance; private set
        lateinit var prefs: com.giantmushroom.asgardchat.data.Prefs; private set
        lateinit var notifier: Notifier; private set
        @Volatile var foreground = false
    }
}
