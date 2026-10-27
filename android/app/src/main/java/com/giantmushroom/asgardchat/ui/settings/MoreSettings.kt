package com.giantmushroom.asgardchat.ui.settings

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings as AndroidSettings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.data.MessageEntity
import com.giantmushroom.asgardchat.engine.ChatEngine
import com.giantmushroom.asgardchat.net.Time
import com.giantmushroom.asgardchat.net.User
import com.giantmushroom.asgardchat.notify.ConnectionService
import com.giantmushroom.asgardchat.ui.components.Avatar
import com.giantmushroom.asgardchat.ui.components.ChatWallpaper
import com.giantmushroom.asgardchat.ui.components.QrCode
import com.giantmushroom.asgardchat.ui.components.glass
import com.giantmushroom.asgardchat.ui.main.stamp
import com.giantmushroom.asgardchat.ui.theme.Brand
import com.giantmushroom.asgardchat.ui.theme.LocalAppearance
import com.giantmushroom.asgardchat.ui.theme.Wallpaper
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File

@Composable
internal fun Card(content: @Composable () -> Unit) =
    Column(Modifier.fillMaxWidth().glass().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { content() }

@Composable
internal fun Footnote(text: String) = Text(text, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
internal fun Choice(title: String, options: List<Pair<String, String>>, selected: String, set: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable { open = true }, verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Box {
            Text(options.firstOrNull { it.first == selected }?.second ?: selected, color = MaterialTheme.colorScheme.primary)
            DropdownMenu(open, { open = false }) { options.forEach { (k, v) -> DropdownMenuItem({ Text(v) }, { open = false; set(k) }) } }
        }
    }
}

/** Wallpaper and text size, added to the Appearance page. */
@Composable
internal fun AppearanceExtras() {
    val a = LocalAppearance.current
    Card {
        Text("Chat wallpaper", fontWeight = FontWeight.SemiBold)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Wallpaper.entries.forEach { w ->
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.size(62.dp, 100.dp).clip(RoundedCornerShape(12.dp))
                        .then(if (a.wallpaper == w) Modifier.background(MaterialTheme.colorScheme.primary).padding(3.dp) else Modifier)
                        .clip(RoundedCornerShape(10.dp)).clickable { a.chooseWallpaper(w) }) { ChatWallpaper(w) }
                    Text(w.title, fontSize = 11.sp)
                }
            }
        }
        Text("Text size", fontWeight = FontWeight.SemiBold)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("A", fontSize = 12.sp)
            Slider(a.textScale, { a.chooseTextScale((it * 20).toInt() / 20f) }, Modifier.weight(1f).padding(horizontal = 8.dp), valueRange = 0.8f..1.3f)
            Text("A", fontSize = 20.sp)
        }
    }
}

@Serializable private data class ContactRow(val user: User, val blocked: Boolean = false)

@Composable
internal fun PrivacyPage() {
    val engine = AsgardApp.engine
    val prefs = AsgardApp.prefs
    val scope = rememberCoroutineScope()
    val me by engine.me.collectAsState()
    val s = me?.settings ?: emptyMap()
    fun bool(k: String, def: Boolean) = s[k]?.jsonPrimitive?.booleanOrNull ?: def
    fun save(k: String, v: kotlinx.serialization.json.JsonElement) = scope.launch {
        runCatching { engine.updateSettings(mapOf(k to v)) }
    }
    var blocked by remember { mutableStateOf<List<ContactRow>>(emptyList()) }
    suspend fun load() { blocked = runCatching { engine.api!!.send<List<ContactRow>>("GET", "/contacts") }.getOrDefault(emptyList()).filter { it.blocked } }
    LaunchedEffect(Unit) { load() }
    val context = LocalContext.current

    Card {
        Text("Who sees what", fontWeight = FontWeight.SemiBold)
        Toggle("Show last seen & online", !bool("hide_last_seen", false)) { save("hide_last_seen", JsonPrimitive(!it)) }
        Toggle("Read receipts", bool("read_receipts", true)) { save("read_receipts", JsonPrimitive(it)) }
        Toggle("Typing indicators", bool("typing_indicators", true)) { save("typing_indicators", JsonPrimitive(it)) }
        Choice("Who can add me to groups", listOf("everyone" to "Everyone", "contacts" to "My contacts"),
            s["who_can_add"]?.jsonPrimitive?.contentOrNull ?: "everyone") { save("who_can_add", JsonPrimitive(it)) }
        Footnote("If you turn off read receipts, you won't see other people's either.")
    }
    Card {
        Text("Security", fontWeight = FontWeight.SemiBold)
        Toggle("Lock Asgard with fingerprint or face", prefs.appLock) { on ->
            com.giantmushroom.asgardchat.AppLock.confirm(context, if (on) "Turn on app lock" else "Turn off app lock") { prefs.appLock = on }
        }
        if (prefs.appLock) Choice("Require after", listOf("0" to "Immediately", "60" to "1 minute", "900" to "15 minutes", "3600" to "1 hour"),
            prefs.lockGraceSeconds.toString()) { prefs.lockGraceSeconds = it.toLong() }
        Toggle("Hide content in recent apps and screenshots", prefs.screenSecurity) { prefs.screenSecurity = it }
        Footnote("Messages, media, calls, reactions and polls are end-to-end encrypted with keys that never leave your devices.")
    }
    Card {
        Text("Blocked", fontWeight = FontWeight.SemiBold)
        if (blocked.isEmpty()) Footnote("No one")
        blocked.forEach { c ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Avatar(c.user.id.toString(), c.user.displayName, 32.dp, mediaID = c.user.avatarMediaID?.toString())
                Text(c.user.displayName, Modifier.padding(start = 10.dp).weight(1f))
                TextButton({ scope.launch { runCatching { engine.api!!.call("DELETE", "/contacts/${c.user.id}") }; load() } }) { Text("Unblock") }
            }
        }
    }
}

@Composable
internal fun NotificationsPage() {
    val prefs = AsgardApp.prefs
    val context = LocalContext.current
    val granted = android.os.Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    var bg by remember { mutableStateOf(ConnectionService.enabled(context)) }
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Status", Modifier.weight(1f)); Text(if (granted) "On" else "Off", color = if (granted) Brand.teal else MaterialTheme.colorScheme.error)
        }
        if (!granted) Button({
            context.startActivity(Intent(AndroidSettings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(AndroidSettings.EXTRA_APP_PACKAGE, context.packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }) { Text("Turn on in Android settings") }
    }
    Card {
        Toggle("Show message preview", prefs.notificationPreview) { prefs.notificationPreview = it }
        Toggle("Sounds", prefs.notificationSound) { prefs.notificationSound = it }
        Toggle("In-app banners", prefs.inAppBanners) { prefs.inAppBanners = it }
        Footnote("Notifications are decrypted on this phone. Your server only ever sends encrypted data.")
    }
    Card {
        Toggle("Stay connected in the background", bg) { bg = it; ConnectionService.setEnabled(context, it) }
        Footnote(if (com.giantmushroom.asgardchat.BuildConfig.HAS_FIREBASE)
            "Only needed if push notifications are blocked on your phone."
        else "This build has no Firebase push, so the app keeps a connection to your server open to deliver messages. Android shows a small permanent notification for it.")
    }
}

@Composable
internal fun ChatsPage() {
    val prefs = AsgardApp.prefs
    var newFolder by remember { mutableStateOf("") }
    Card {
        Text("Typing", fontWeight = FontWeight.SemiBold)
        Toggle("Enter key sends", prefs.enterToSend) { prefs.enterToSend = it }
        Choice("Double-tap reaction", listOf("❤️", "👍", "😂", "🔥", "⚡️").map { it to it }, prefs.doubleTapReaction) { prefs.doubleTapReaction = it }
    }
    Card {
        Text("Chat folders", fontWeight = FontWeight.SemiBold)
        prefs.customFolders.forEach { f ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(f, Modifier.weight(1f))
                TextButton({ prefs.customFolders = prefs.customFolders - f }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(newFolder, { newFolder = it }, Modifier.weight(1f), label = { Text("New folder") }, singleLine = true)
            TextButton({ val n = newFolder.trim(); if (n.isNotEmpty() && n !in prefs.customFolders) prefs.customFolders = prefs.customFolders + n; newFolder = "" }) { Text("Add") }
        }
        Footnote("Long-press a chat in the list to move it into a folder.")
    }
    Card {
        Text("Auto-download media", fontWeight = FontWeight.SemiBold)
        Toggle("On Wi-Fi", prefs.autoDownloadWifi) { prefs.autoDownloadWifi = it }
        Toggle("On mobile data", prefs.autoDownloadCellular) { prefs.autoDownloadCellular = it }
    }
}

@Composable
internal fun StoragePage() {
    val engine = AsgardApp.engine
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var bytes by remember { mutableStateOf(0L) }
    var count by remember { mutableIntStateOf(0) }
    fun refresh() = scope.launch {
        bytes = File(context.cacheDir, "media").walkTopDown().filter { it.isFile }.sumOf { it.length() }
        count = engine.dao.messageCount()
    }
    LaunchedEffect(Unit) { refresh() }
    Card {
        Row { Text("Media cache", Modifier.weight(1f)); Text(android.text.format.Formatter.formatShortFileSize(context, bytes)) }
        Row { Text("Messages on this phone", Modifier.weight(1f)); Text("$count") }
        TextButton({ File(context.cacheDir, "media").deleteRecursively(); File(context.cacheDir, "shared").deleteRecursively(); refresh() }) {
            Text("Clear media cache", color = MaterialTheme.colorScheme.error)
        }
        Footnote("Clearing the cache keeps your messages. Media downloads again when you open it.")
    }
}

@Composable
internal fun StarredPage(open: (String) -> Unit) {
    val engine = AsgardApp.engine
    val starred by engine.dao.starred().collectAsState(emptyList())
    if (starred.isEmpty()) Card { Footnote("Long-press a message and choose Star to keep it here.") }
    starred.forEach { m: MessageEntity ->
        Column(Modifier.fillMaxWidth().glass().clickable { open(m.conversationID) }.padding(14.dp)) {
            Row { Text(engine.name(m.senderUserID), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f)); Text(stamp(m.sentAt), fontSize = 12.sp) }
            Text(m.content?.let { ChatEngine.preview(it) } ?: "", maxLines = 4)
        }
    }
}

// ---- Server admin ----

@Serializable private data class AdminStats(
    val users: Int = 0, val conversations: Int = 0, val messages: Int = 0, val devices: Int = 0,
    @SerialName("media_bytes") val mediaBytes: Long = 0, @SerialName("database_bytes") val databaseBytes: Long = 0,
    @SerialName("online_users") val onlineUsers: Int = 0, val version: String = "",
    @SerialName("push_enabled") val pushEnabled: Boolean = false, @SerialName("calls_enabled") val callsEnabled: Boolean = false,
)
@Serializable private data class AdminUser(
    val id: String, val username: String, @SerialName("display_name") val displayName: String,
    @SerialName("is_admin") val isAdmin: Boolean = false, @SerialName("is_bot") val isBot: Boolean = false,
    val online: Boolean = false, val disabled: Boolean = false, @SerialName("device_count") val deviceCount: Int = 0,
)
@Serializable private data class Invite(
    val code: String, val note: String = "", @SerialName("max_uses") val maxUses: Int = 1, val uses: Int = 0,
    @SerialName("make_admin") val makeAdmin: Boolean = false, @SerialName("expires_at") val expiresAt: Time? = null, val url: String = "",
)
@Serializable private data class TempPassword(@SerialName("temporary_password") val password: String)

@Composable
internal fun AdminPage() {
    val engine = AsgardApp.engine
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var stats by remember { mutableStateOf<AdminStats?>(null) }
    var users by remember { mutableStateOf<List<AdminUser>>(emptyList()) }
    var invites by remember { mutableStateOf<List<Invite>>(emptyList()) }
    var creating by remember { mutableStateOf(false) }
    var shown by remember { mutableStateOf<Invite?>(null) }
    var tempPassword by remember { mutableStateOf<String?>(null) }
    var testResult by remember { mutableStateOf<String?>(null) }
    suspend fun load() {
        val api = engine.api ?: return
        stats = runCatching { api.send<AdminStats>("GET", "/admin/stats") }.getOrNull()
        users = runCatching { api.send<List<AdminUser>>("GET", "/admin/users") }.getOrDefault(emptyList())
        invites = runCatching { api.send<List<Invite>>("GET", "/admin/invites") }.getOrDefault(emptyList())
    }
    LaunchedEffect(Unit) { load() }

    stats?.let { st ->
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("${st.users}" to "Users", "${st.onlineUsers}" to "Online", "${st.conversations}" to "Chats", "${st.messages}" to "Messages",
                android.text.format.Formatter.formatShortFileSize(context, st.mediaBytes) to "Media",
                android.text.format.Formatter.formatShortFileSize(context, st.databaseBytes) to "Database").forEach { (v, l) ->
                Column(Modifier.width(104.dp).glass(RoundedCornerShape(16.dp)).padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(v, fontWeight = FontWeight.Bold, fontSize = 18.sp); Text(l, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        Card {
            Row { Text("Push", Modifier.weight(1f)); Text(if (st.pushEnabled) "On" else "Off") }
            Row { Text("Calls", Modifier.weight(1f)); Text(if (st.callsEnabled) "Configured" else "Not configured") }
            Row { Text("Server version", Modifier.weight(1f)); Text(st.version) }
            TextButton({
                scope.launch {
                    testResult = runCatching { engine.api!!.execute("POST", "/admin/push/test", null) }.fold({ "Sent. Check your devices." }, { it.message })
                }
            }) { Text("Send a test notification to my devices") }
            testResult?.let { Footnote(it) }
        }
    }
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Invites", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            TextButton({ creating = true }) { Text("Create") }
        }
        invites.forEach { inv ->
            Row(Modifier.fillMaxWidth().clickable { shown = inv }, verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(inv.code + if (inv.makeAdmin) "  · admin" else "", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
                    if (inv.note.isNotBlank()) Footnote(inv.note)
                }
                Text("${inv.uses}/${inv.maxUses}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton({ scope.launch { runCatching { engine.api!!.call("DELETE", "/admin/invites/${inv.code}") }; load() } }) {
                    Text("Revoke", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
    Card {
        Text("Users", fontWeight = FontWeight.SemiBold)
        users.forEach { u -> AdminUserRow(u, engine.myID == u.id, { scope.launch { load() } }) { tempPassword = it } }
    }
    if (creating) CreateInviteDialog({ creating = false }) { inv -> creating = false; shown = inv; scope.launch { load() } }
    shown?.let { inv ->
        AlertDialog({ shown = null }, confirmButton = {
            TextButton({
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
                    .putExtra(Intent.EXTRA_TEXT, "Join me on Asgard Chat: ${inv.url}"), null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }) { Text("Share") }
        }, dismissButton = { TextButton({ shown = null }) { Text("Done") } }, title = { Text("Invite") }, text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (inv.url.isNotBlank()) QrCode(inv.url, 200.dp)
                Text(inv.code, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 18.sp)
            }
        })
    }
    tempPassword?.let { pw ->
        AlertDialog({ tempPassword = null }, confirmButton = { TextButton({ tempPassword = null }) { Text("Done") } },
            title = { Text("Temporary password") }, text = { Text(pw, fontFamily = FontFamily.Monospace) })
    }
}

@Composable
private fun AdminUserRow(u: AdminUser, isMe: Boolean, changed: () -> Unit, showPassword: (String) -> Unit) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    fun patch(k: String, v: Boolean) = scope.launch {
        runCatching { engine.api!!.call("PATCH", "/admin/users/${u.id}", buildJsonObject { put(k, v) }) }; changed()
    }
    Box {
        Row(Modifier.fillMaxWidth().clickable(enabled = !isMe) { menu = true }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Avatar(u.id, u.displayName, 34.dp, online = u.online)
            Column(Modifier.padding(start = 10.dp).weight(1f)) {
                Text(u.displayName + (if (u.isAdmin) " 👑" else "") + (if (u.disabled) "  (disabled)" else ""))
                Footnote("@${u.username} · ${u.deviceCount} devices")
            }
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem({ Text(if (u.isAdmin) "Remove admin" else "Make admin") }, { menu = false; patch("is_admin", !u.isAdmin) })
            DropdownMenuItem({ Text(if (u.disabled) "Enable" else "Disable") }, { menu = false; patch("disabled", !u.disabled) })
            if (!u.isBot) DropdownMenuItem({ Text("Reset password") }, {
                menu = false
                scope.launch { runCatching { engine.api!!.send<TempPassword>("POST", "/admin/users/${u.id}/reset-password") }.getOrNull()?.let { showPassword(it.password) } }
            })
            DropdownMenuItem({ Text("Delete user", color = MaterialTheme.colorScheme.error) }, {
                menu = false
                scope.launch { runCatching { engine.api!!.call("DELETE", "/admin/users/${u.id}") }; changed() }
            })
        }
    }
}

@Composable
private fun CreateInviteDialog(dismiss: () -> Unit, created: (Invite) -> Unit) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    var note by remember { mutableStateOf("") }
    var uses by remember { mutableIntStateOf(1) }
    var hours by remember { mutableStateOf("168") }
    var admin by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(dismiss, title = { Text("New invite") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(note, { note = it }, label = { Text("Note (e.g. For Mum)") }, singleLine = true)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Uses: $uses", Modifier.weight(1f))
                TextButton({ if (uses > 1) uses-- }) { Text("−") }; TextButton({ if (uses < 100) uses++ }) { Text("+") }
            }
            Choice("Expires", listOf("24" to "1 day", "168" to "1 week", "720" to "30 days", "0" to "Never"), hours) { hours = it }
            Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(admin, { admin = it }); Text("Make admin") }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }, confirmButton = {
        TextButton({
            scope.launch {
                runCatching {
                    engine.api!!.send<Invite>("POST", "/admin/invites", buildJsonObject {
                        put("note", note); put("max_uses", uses); put("expires_hours", hours.toInt()); put("make_admin", admin)
                    })
                }.onSuccess(created).onFailure { error = it.message }
            }
        }) { Text("Create") }
    }, dismissButton = { TextButton(dismiss) { Text("Cancel") } })
}

@Composable
internal fun AboutCard() {
    val engine = AsgardApp.engine
    val info by engine.serverInfo.collectAsState()
    val context = LocalContext.current
    val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: ""
    Card {
        Text("Asgard Chat $version", fontWeight = FontWeight.Bold)
        Row { Text("Server", Modifier.weight(1f)); Text(info?.name ?: "—") }
        Row { Text("Address", Modifier.weight(1f)); Text(engine.account?.serverURL?.removePrefix("https://")?.removePrefix("http://") ?: "—") }
        Row { Text("Server version", Modifier.weight(1f)); Text(info?.version ?: "—") }
    }
    Card {
        Text("Encryption", fontWeight = FontWeight.SemiBold)
        Footnote("Each message gets a fresh key, wrapped for every device in the chat with X25519, sealed with ChaCha20-Poly1305 and signed with Ed25519. The protocol is open source.")
        TextButton({ context.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://github.com/Sausagerolls/asgard-chat")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }) {
            Text("Source code")
        }
    }
}
