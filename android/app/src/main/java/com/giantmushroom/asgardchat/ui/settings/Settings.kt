package com.giantmushroom.asgardchat.ui.settings

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.engine.HistoryState
import com.giantmushroom.asgardchat.engine.disableHistory
import com.giantmushroom.asgardchat.engine.enableHistory
import com.giantmushroom.asgardchat.engine.importHistory
import com.giantmushroom.asgardchat.engine.backfillHistory
import com.giantmushroom.asgardchat.engine.recoveryKeyForDisplay
import com.giantmushroom.asgardchat.engine.refreshHistoryStatus
import com.giantmushroom.asgardchat.engine.restoreHistory
import com.giantmushroom.asgardchat.net.ApiError
import com.giantmushroom.asgardchat.net.DeviceInfo
import com.giantmushroom.asgardchat.ui.components.AuroraBackground
import com.giantmushroom.asgardchat.ui.components.Avatar
import com.giantmushroom.asgardchat.ui.components.QrCode
import com.giantmushroom.asgardchat.ui.components.glass
import com.giantmushroom.asgardchat.ui.components.rememberQrScanner
import com.giantmushroom.asgardchat.ui.theme.Accent
import com.giantmushroom.asgardchat.ui.theme.BubbleStyle
import com.giantmushroom.asgardchat.ui.theme.Brand
import com.giantmushroom.asgardchat.ui.theme.LocalAppearance
import com.giantmushroom.asgardchat.ui.theme.ThemeChoice
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

private enum class Page { Root, Profile, Appearance, Privacy, Notifications, Chats, Devices, Storage, Starred, History, Admin, About }

@Composable
fun SettingsTab(openChat: (String) -> Unit = {}) {
    var page by rememberSaveable { mutableStateOf(Page.Root) }
    BackHandler(page != Page.Root) { page = Page.Root }
    Box(Modifier.fillMaxSize()) {
        AuroraBackground(0.4f)
        when (page) {
            Page.Root -> SettingsRoot { page = it }
            Page.Profile -> Sub("Profile", { page = Page.Root }) { ProfilePage() }
            Page.Appearance -> Sub("Appearance", { page = Page.Root }) { AppearancePage() }
            Page.Privacy -> Sub("Privacy & security", { page = Page.Root }) { PrivacyPage() }
            Page.Notifications -> Sub("Notifications", { page = Page.Root }) { NotificationsPage() }
            Page.Chats -> Sub("Chats", { page = Page.Root }) { ChatsPage() }
            Page.Storage -> Sub("Storage & data", { page = Page.Root }) { StoragePage() }
            Page.Starred -> Sub("Starred messages", { page = Page.Root }) { StarredPage(openChat) }
            Page.Admin -> Sub("Server admin", { page = Page.Root }) { AdminPage() }
            Page.Devices -> Sub("Devices", { page = Page.Root }) { DevicesPage() }
            Page.History -> Sub("Message history", { page = Page.Root }) { HistoryPage() }
            Page.About -> Sub("About", { page = Page.Root }) { AboutCard() }
        }
    }
}

@Composable
private fun SettingsRoot(open: (Page) -> Unit) {
    val engine = AsgardApp.engine
    val me by engine.me.collectAsState()
    val scope = rememberCoroutineScope()
    var confirmSignOut by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp).padding(bottom = 100.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Settings", fontSize = 34.sp, fontWeight = FontWeight.Bold)
        Row(Modifier.fillMaxWidth().glass().clickable { open(Page.Profile) }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Avatar(me?.id?.toString(), me?.displayName ?: "", 60.dp, mediaID = me?.avatarMediaID?.toString())
            Column(Modifier.padding(start = 14.dp).weight(1f)) {
                Text(me?.displayName ?: "", fontWeight = FontWeight.Bold, fontSize = 20.sp)
                Text("@${me?.username ?: ""}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (!me?.bio.isNullOrBlank()) Text(me!!.bio, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null)
        }
        Column(Modifier.glass()) {
            Row_(Icons.Filled.Palette, Color(0xFFAF52DE), "Appearance") { open(Page.Appearance) }
            Row_(Icons.Filled.Lock, Color(0xFF007AFF), "Privacy & security") { open(Page.Privacy) }
            Row_(Icons.Filled.Notifications, Color(0xFFFF3B30), "Notifications") { open(Page.Notifications) }
            Row_(Icons.AutoMirrored.Filled.Chat, Color(0xFF34C759), "Chats") { open(Page.Chats) }
            Row_(Icons.Filled.Devices, Color(0xFFFF9500), "Devices") { open(Page.Devices) }
            Row_(Icons.Filled.Storage, Color(0xFF30B0C7), "Storage & data") { open(Page.Storage) }
            Row_(Icons.Filled.Star, Color(0xFFFFCC00), "Starred messages") { open(Page.Starred) }
            Row_(Icons.Filled.History, Color(0xFF5856D6), "Message history") { open(Page.History) }
        }
        val info by engine.serverInfo.collectAsState()
        val connection by engine.connection.collectAsState()
        val connected = connection == com.giantmushroom.asgardchat.net.ConnectionState.connected
        Column(Modifier.glass()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(30.dp).background(Color(0xFF32ADE6), RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Public, null, tint = Color.White, modifier = Modifier.size(18.dp))
                }
                Column(Modifier.padding(start = 12.dp).weight(1f)) {
                    Text(info?.name ?: "Server")
                    Text(if (connected) "Connected" else "Connecting…", fontSize = 12.sp,
                        color = if (connected) Color(0xFF34C759) else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(engine.account?.serverURL?.let { android.net.Uri.parse(it).host } ?: "—", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (me?.isAdmin == true) Row_(Icons.Filled.Dns, Color(0xFF5856D6), "Server admin") { open(Page.Admin) }
        }
        Column(Modifier.glass()) {
            Row_(Icons.Filled.Info, Color.Gray, "About Asgard") { open(Page.About) }
        }
        TextButton({ confirmSignOut = true }, Modifier.fillMaxWidth().glass()) { Text("Sign out", color = MaterialTheme.colorScheme.error) }
    }
    if (confirmSignOut) AlertDialog({ confirmSignOut = false }, confirmButton = {
        TextButton({ confirmSignOut = false; scope.launch { engine.signOut() } }) { Text("Sign out", color = MaterialTheme.colorScheme.error) }
    }, dismissButton = { TextButton({ confirmSignOut = false }) { Text("Cancel") } }, title = { Text("Sign out of this phone?") },
        text = { Text("This phone's keys and stored messages are deleted. Your other devices keep working.") })
}

@Composable
internal fun Row_(icon: ImageVector, color: Color, title: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)).background(color), contentAlignment = Alignment.Center) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(18.dp)) }
        Text(title, Modifier.padding(start = 12.dp).weight(1f), fontSize = 16.sp)
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Sub(title: String, back: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp).padding(bottom = 100.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(back, Modifier.glass(CircleShape)) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Text(title, Modifier.padding(start = 12.dp), fontSize = 24.sp, fontWeight = FontWeight.Bold)
        }
        content()
    }
}

@Composable
private fun ProfilePage() {
    val engine = AsgardApp.engine
    val me by engine.me.collectAsState()
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(me?.displayName ?: "") }
    var bio by remember { mutableStateOf(me?.bio ?: "") }
    var saved by remember { mutableStateOf(false) }
    val context = LocalContext.current
    var cropSource by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    val pickPhoto = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            cropSource = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { com.giantmushroom.asgardchat.ui.components.decodePhoto(context, uri) }
        }
    }
    cropSource?.let { bmp ->
        com.giantmushroom.asgardchat.ui.components.AvatarCropper(bmp, onCancel = { cropSource = null }) { jpeg ->
            cropSource = null
            scope.launch { runCatching { engine.updateProfile(avatarJpeg = jpeg) } }
        }
    }
    Column(Modifier.glass().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.fillMaxWidth().clickable { pickPhoto.launch(androidx.activity.result.PickVisualMediaRequest(androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly)) },
            contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Avatar(me?.id?.toString(), name, 96.dp, mediaID = me?.avatarMediaID?.toString())
                Text("Change photo", color = MaterialTheme.colorScheme.primary, fontSize = 13.sp)
            }
        }
        OutlinedTextField(name, { name = it; saved = false }, Modifier.fillMaxWidth(), label = { Text("Name") }, singleLine = true)
        OutlinedTextField(bio, { bio = it; saved = false }, Modifier.fillMaxWidth(), label = { Text("Bio") })
        Button({
            scope.launch {
                runCatching { engine.updateProfile(displayName = name, bio = bio) }
                saved = true
            }
        }) { Text(if (saved) "Saved ✓" else "Save") }
    }
}

@Composable
private fun AppearancePage() {
    val a = LocalAppearance.current
    Column(Modifier.glass().padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Theme", fontWeight = FontWeight.SemiBold)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ThemeChoice.entries.forEach { t -> Chip(t.name, a.theme == t) { a.update(theme = t) } }
        }
        Text("Accent", fontWeight = FontWeight.SemiBold)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Accent.entries.forEach { c ->
                Box(Modifier.size(38.dp).clip(CircleShape).background(c.fill)
                    .border(if (a.accent == c) 3.dp else 0.dp, MaterialTheme.colorScheme.onSurface, CircleShape).clickable { a.update(accent = c) })
            }
        }
        Text("Bubbles", fontWeight = FontWeight.SemiBold)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { BubbleStyle.entries.forEach { b -> Chip(b.name, a.bubbles == b) { a.update(bubbles = b) } } }
        Toggle("Animated backgrounds", a.animatedBackgrounds) { a.update(animatedBackgrounds = it) }
        Toggle("Message animations", a.messageAnimations) { a.update(messageAnimations = it) }
    }
    AppearanceExtras()
}

@Composable
internal fun Chip(title: String, on: Boolean, onClick: () -> Unit) =
    Text(title, Modifier.clip(RoundedCornerShape(50)).background(if (on) MaterialTheme.colorScheme.primary else Color.White.copy(alpha = 0.1f))
        .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 7.dp), color = if (on) Color.White else MaterialTheme.colorScheme.onSurface)

@Composable
internal fun Toggle(title: String, value: Boolean, set: (Boolean) -> Unit) = Row(verticalAlignment = Alignment.CenterVertically) {
    Text(title, Modifier.weight(1f)); Switch(value, set)
}

@Serializable private data class LinkCode(val code: String, val uri: String)

@Composable
private fun DevicesPage() {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    var devices by remember { mutableStateOf<List<DeviceInfo>>(emptyList()) }
    var link by remember { mutableStateOf<LinkCode?>(null) }
    suspend fun load() { devices = runCatching { engine.api!!.send<List<DeviceInfo>>("GET", "/me/devices") }.getOrDefault(emptyList()) }
    LaunchedEffect(Unit) { load() }
    Column(Modifier.glass().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        val l = link
        if (l == null) Button({ scope.launch { link = runCatching { engine.api!!.send<LinkCode>("POST", "/devices/link") }.getOrNull() } }) { Text("Link a device") }
        else {
            Text("Scan with your new device", fontWeight = FontWeight.SemiBold)
            QrCode(l.uri, 220.dp)
            Text(l.code, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 18.sp)
            Text("Your message history is sent to it automatically, end-to-end encrypted.", fontSize = 12.sp, textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    Column(Modifier.glass()) {
        devices.forEach { d ->
            Row(Modifier.fillMaxWidth().padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(d.name?.ifBlank { null } ?: d.platform ?: "Device", fontWeight = FontWeight.SemiBold)
                    Text(if (d.current == true) "This phone" else d.platform ?: "", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (d.current != true) TextButton({ scope.launch { runCatching { engine.api!!.call("DELETE", "/me/devices/${d.id}") }; load() } }) {
                    Text("Remove", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

@Composable
private fun HistoryPage() {
    val engine = AsgardApp.engine
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val h by engine.history.collectAsState()
    var shown by remember { mutableStateOf<String?>(null) }
    var isNew by remember { mutableStateOf(false) }
    var typed by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmOff by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { engine.refreshHistoryStatus() }
    fun restore(text: String) = scope.launch {
        error = null
        try { engine.restoreHistory(text); typed = "" } catch (e: Exception) { error = (e as? ApiError)?.message ?: e.message }
    }
    val scan = rememberQrScanner("Scan the recovery key QR code on your other device") { payload ->
        val key = android.net.Uri.parse(payload).takeIf { it.scheme == "asgard" && it.host == "history" }?.getQueryParameter("key")
        if (key != null) { typed = key; restore(key) } else error = "That QR code isn't an Asgard recovery key."
    }

    Column(Modifier.glass().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(when { h.enabled == true && h.hasKey -> "History sync is on"; h.enabled == true -> "Restore your message history"; h.enabled == false -> "History sync is off"; else -> "Checking…" },
            fontWeight = FontWeight.Bold, fontSize = 18.sp)
        Text(when { h.enabled == true && h.hasKey -> "New devices you link get your full message history, end-to-end encrypted."
            h.enabled == true -> "Scan the QR code from a device you already use, or type your recovery key."
            else -> "New devices only see messages sent after they join." }, color = MaterialTheme.colorScheme.onSurfaceVariant)
        h.progress?.let { LinearProgressIndicator(Modifier.fillMaxWidth()); Text(it, fontSize = 12.sp) }
    }
    when {
        h.enabled == false -> Button({ scope.launch { try { shown = engine.enableHistory(); isNew = true } catch (e: Exception) { error = (e as? ApiError)?.message } } },
            Modifier.fillMaxWidth()) { Text("Turn on history sync") }
        h.enabled == true && !h.hasKey -> Column(Modifier.glass().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(scan, Modifier.fillMaxWidth()) { Icon(Icons.Filled.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text("Scan QR code") }
            OutlinedTextField(typed, { typed = it }, Modifier.fillMaxWidth(), label = { Text("Recovery key") }, textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace))
            OutlinedButton({ restore(typed) }, enabled = typed.length >= 40 && !h.working) { Text("Restore messages") }
        }
        h.enabled == true -> Column(Modifier.glass(), verticalArrangement = Arrangement.spacedBy(0.dp)) {
            Row_(Icons.Filled.Key, Brand.gold, "Show recovery key & QR code") { shown = engine.recoveryKeyForDisplay(); isNew = false }
            Row_(Icons.Filled.History, Brand.teal, "Sync history now") { scope.launch { engine.backfillHistory(); engine.importHistory() } }
            TextButton({ confirmOff = true }, Modifier.fillMaxWidth()) { Text("Turn off history sync", color = MaterialTheme.colorScheme.error) }
        }
    }
    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }

    shown?.let { key ->
        var saved by remember(key) { mutableStateOf(!isNew) }
        AlertDialog(onDismissRequest = { if (saved) shown = null }, confirmButton = { TextButton({ shown = null }, enabled = saved) { Text("Done") } },
            dismissButton = { TextButton({
                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Recovery key", key))
            }) { Text("Copy") } },
            title = { Text("Your recovery key") },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("To add a device to sync, scan this from its Message history screen. Keep a copy somewhere safe.", fontSize = 13.sp)
                    QrCode("asgard://history?key=$key", 180.dp)
                    Text(key.replace("-", " "), fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                    if (isNew) Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(saved, { saved = it }); Text("I've saved it somewhere safe", fontSize = 13.sp) }
                }
            })
    }
    if (confirmOff) AlertDialog({ confirmOff = false }, confirmButton = {
        TextButton({ confirmOff = false; scope.launch { runCatching { engine.disableHistory() } } }) { Text("Turn off", color = MaterialTheme.colorScheme.error) }
    }, dismissButton = { TextButton({ confirmOff = false }) { Text("Cancel") } }, title = { Text("Turn off history sync?") },
        text = { Text("The encrypted copies on your server are deleted. New devices won't see older messages.") })
}

/** Nudge on the chat list until history sync is set up on this phone. */
@Composable
fun HistoryNudge(modifier: Modifier = Modifier) {
    val engine = AsgardApp.engine
    val h by engine.history.collectAsState()
    val prefs = LocalContext.current.getSharedPreferences("asgard", Context.MODE_PRIVATE)
    var dismissed by remember { mutableStateOf(prefs.getBoolean("historyNudgeDismissed", false)) }
    var open by remember { mutableStateOf(false) }
    val enabled = h.enabled ?: return
    if (!((enabled && !h.hasKey) || (!enabled && !dismissed) || h.working)) return
    Row(modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (h.working) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Icon(Icons.Filled.Key, null, tint = Brand.gold)
        Column(Modifier.padding(start = 12.dp).weight(1f)) {
            Text(if (h.working) "Restoring messages" else if (enabled) "Restore your message history" else "Keep your messages on new devices", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text(h.progress ?: if (enabled) "Scan your recovery key QR code to read older messages here." else "Turn on history sync and save a recovery key.",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (!h.working) {
            Button({ open = true }) { Text(if (enabled) "Restore" else "Set up") }
            if (!enabled) IconButton({ dismissed = true; prefs.edit().putBoolean("historyNudgeDismissed", true).apply() }) { Text("✕") }
        }
    }
    if (open) androidx.compose.ui.window.Dialog({ open = false }) {
        Column(Modifier.glass(RoundedCornerShape(28.dp), strong = true).background(MaterialTheme.colorScheme.background.copy(alpha = 0.9f)).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            HistoryPage()
            TextButton({ open = false }, Modifier.align(Alignment.End)) { Text("Done") }
        }
    }
}

@Composable
private fun AboutPage() {
    val engine = AsgardApp.engine
    val info by engine.serverInfo.collectAsState()
    Column(Modifier.glass().padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Asgard Chat for Android", fontWeight = FontWeight.Bold)
        Text("Server: ${engine.account?.serverURL ?: "—"}")
        Text("Server version: ${info?.version ?: "—"}")
        Text("Every message is encrypted on this phone with a fresh key, wrapped for each device with X25519, sealed with ChaCha20-Poly1305 and signed with Ed25519.",
            fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun NotificationsCard() {
    val context = LocalContext.current
    var bg by remember { mutableStateOf(com.giantmushroom.asgardchat.notify.ConnectionService.enabled(context)) }
    Column(Modifier.glass().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Notifications", fontWeight = FontWeight.SemiBold)
        Toggle("Stay connected in the background", bg) { bg = it; com.giantmushroom.asgardchat.notify.ConnectionService.setEnabled(context, it) }
        Text(if (com.giantmushroom.asgardchat.BuildConfig.HAS_FIREBASE)
            "This build uses Firebase push. Background connection is only needed if pushes are blocked on your phone."
            else "This build has no Firebase push, so the app keeps a connection to your server open to deliver messages. Android shows a small permanent notification for it.",
            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
