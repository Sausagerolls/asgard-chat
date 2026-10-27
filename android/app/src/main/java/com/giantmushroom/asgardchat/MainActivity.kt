package com.giantmushroom.asgardchat

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.fragment.app.FragmentActivity
import android.view.WindowManager
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.giantmushroom.asgardchat.ui.components.AuroraBackground
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import com.giantmushroom.asgardchat.ui.Root
import com.giantmushroom.asgardchat.ui.theme.AsgardTheme
import com.giantmushroom.asgardchat.ui.theme.LocalAppearance

class MainActivity : FragmentActivity() {
    private var locked = mutableStateOf(false)
    /** Chat to open from a notification or link. */
    val openChat = mutableStateOf<String?>(null)
    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(0), navigationBarStyle = SystemBarStyle.dark(0))
        super.onCreate(savedInstanceState)
        handle(intent)
        if (Build.VERSION.SDK_INT >= 33) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        setContent {
            val secure = AsgardApp.prefs.screenSecurity
            LaunchedEffect(secure) {
                if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            CompositionLocalProvider(LocalAppearance provides AsgardApp.appearance) {
                AsgardTheme(AsgardApp.appearance) {
                    Root(openChat)
                    if (locked.value) Box(Modifier.fillMaxSize()) {
                        AuroraBackground()
                        Button({ unlock() }, Modifier.align(Alignment.Center)) { Text("Unlock Asgard") }
                    }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (AppLock.required()) { locked.value = true; unlock() }
    }

    override fun onStop() {
        super.onStop()
        AppLock.backgroundedAt = System.currentTimeMillis()
    }

    private fun unlock() = AppLock.confirm(this, "Unlock your messages") { locked.value = false }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        intent?.getStringExtra(EXTRA_CONVERSATION)?.let { openChat.value = it }
        intent?.data?.takeIf { it.scheme == "asgard" && it.host == "chat" }?.lastPathSegment?.let { openChat.value = it.lowercase() }
    }

    companion object { const val EXTRA_CONVERSATION = "conversation" }
}
