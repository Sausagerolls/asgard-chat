package com.giantmushroom.asgardchat.data

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Per-device preferences (same options as the iPhone app), observable from Compose. */
class Prefs(context: Context) {
    private val p = context.getSharedPreferences("asgard-prefs", Context.MODE_PRIVATE)

    private inner class Bool(private val key: String, default: Boolean) {
        var value by mutableStateOf(p.getBoolean(key, default))
        fun set(v: Boolean) { value = v; p.edit().putBoolean(key, v).apply() }
    }
    private inner class Str(private val key: String, default: String) {
        var value by mutableStateOf(p.getString(key, default)!!)
        fun set(v: String) { value = v; p.edit().putString(key, v).apply() }
    }
    private inner class Num(private val key: String, default: Long) {
        var value by mutableStateOf(p.getLong(key, default))
        fun set(v: Long) { value = v; p.edit().putLong(key, v).apply() }
    }

    // Chats
    private val enterSends = Bool("enterToSend", false)
    private val doubleTap = Str("doubleTapReaction", "❤️")
    private val folders = Str("customFolders", "")
    private val wifi = Bool("autoDownloadWifi", true)
    private val cellular = Bool("autoDownloadCellular", true)
    // Notifications
    private val preview = Bool("notifPreview", true)
    private val sound = Bool("notifSound", true)
    private val inApp = Bool("inAppBanners", true)
    // Privacy
    private val lock = Bool("appLock", false)
    private val grace = Num("lockGraceSeconds", 0)
    private val secure = Bool("screenSecurity", false)

    var enterToSend get() = enterSends.value; set(v) = enterSends.set(v)
    var doubleTapReaction get() = doubleTap.value; set(v) = doubleTap.set(v)
    var customFolders: List<String>
        get() = folders.value.split("|").filter { it.isNotBlank() }
        set(v) = folders.set(v.joinToString("|"))
    var autoDownloadWifi get() = wifi.value; set(v) = wifi.set(v)
    var autoDownloadCellular get() = cellular.value; set(v) = cellular.set(v)
    var notificationPreview get() = preview.value; set(v) = preview.set(v)
    var notificationSound get() = sound.value; set(v) = sound.set(v)
    var inAppBanners get() = inApp.value; set(v) = inApp.set(v)
    var appLock get() = lock.value; set(v) = lock.set(v)
    var lockGraceSeconds get() = grace.value; set(v) = grace.set(v)
    var screenSecurity get() = secure.value; set(v) = secure.set(v)
}
