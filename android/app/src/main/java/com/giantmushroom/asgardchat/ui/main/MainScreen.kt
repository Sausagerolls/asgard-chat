package com.giantmushroom.asgardchat.ui.main

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.data.ConversationEntity
import com.giantmushroom.asgardchat.net.ConversationKind
import com.giantmushroom.asgardchat.ui.calls.CallOverlay
import com.giantmushroom.asgardchat.ui.calls.CallsTab
import com.giantmushroom.asgardchat.ui.chat.ChatScreen
import com.giantmushroom.asgardchat.ui.chat.NewChatSheet
import com.giantmushroom.asgardchat.ui.components.AuroraBackground
import com.giantmushroom.asgardchat.ui.components.Avatar
import com.giantmushroom.asgardchat.ui.components.Badge
import com.giantmushroom.asgardchat.ui.components.glass
import com.giantmushroom.asgardchat.ui.settings.HistoryNudge
import com.giantmushroom.asgardchat.ui.settings.SettingsTab
import com.giantmushroom.asgardchat.ui.theme.Brand
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit

enum class Tab(val title: String, val icon: ImageVector) { Chats("Chats", Icons.AutoMirrored.Filled.Chat), Calls("Calls", Icons.Filled.Call), Settings("Settings", Icons.Filled.Settings) }

@Composable
fun MainScreen(openChat: MutableState<String?>) {
    var tab by rememberSaveable { mutableStateOf(Tab.Chats) }
    var chat by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(openChat.value) { openChat.value?.let { chat = it; tab = Tab.Chats; openChat.value = null } }
    val convs by AsgardApp.engine.dao.conversations().collectAsState(emptyList())
    val unread = convs.filter { !it.isMuted && !it.archived }.sumOf { it.unread }

    Box(Modifier.fillMaxSize()) {
        when (tab) {
            Tab.Chats -> ChatListScreen(convs) { chat = it }
            Tab.Calls -> CallsTab { chat = it; tab = Tab.Chats }
            Tab.Settings -> SettingsTab { chat = it; tab = Tab.Chats }
        }
        if (chat == null) TabBar(tab, unread, Modifier.align(Alignment.BottomCenter)) { tab = it }
        AnimatedVisibility(chat != null, enter = slideInHorizontally { it } + fadeIn(), exit = slideOutHorizontally { it } + fadeOut()) {
            chat?.let { id -> ChatScreen(id) { chat = null } }
        }
        CallOverlay()
    }
    androidx.activity.compose.BackHandler(chat != null) { chat = null }
}

/** Floating glass capsule tab bar, like iOS 26. */
@Composable
private fun TabBar(selected: Tab, unread: Int, modifier: Modifier, onSelect: (Tab) -> Unit) {
    Row(modifier.navigationBarsPadding().padding(bottom = 10.dp).glass(RoundedCornerShape(32.dp), strong = true).padding(6.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Tab.entries.forEach { t ->
            val on = t == selected
            Column(Modifier.clip(RoundedCornerShape(26.dp)).background(if (on) Color.White.copy(alpha = 0.14f) else Color.Transparent)
                .clickable { onSelect(t) }.padding(horizontal = 22.dp, vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Box {
                    Icon(t.icon, t.title, tint = if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(24.dp))
                    if (t == Tab.Chats && unread > 0) Box(Modifier.align(Alignment.TopEnd).padding(start = 14.dp)) {
                        Box(Modifier.clip(CircleShape).background(Color(0xFFFF3B30)).padding(horizontal = 5.dp)) { Text("$unread", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold) }
                    }
                }
                Text(t.title, fontSize = 11.sp, color = if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}

/** A chat filter: the built-in ones, or a folder you made in Settings › Chats. */
data class FolderChoice(val builtIn: Folder? = Folder.All, val custom: String? = null) {
    val title get() = custom ?: builtIn!!.title
    fun includes(c: ConversationEntity) = custom?.let { !c.archived && c.folder == it } ?: builtIn!!.includes(c)
}

enum class Folder(val title: String) { All("All"), Unread("Unread"), People("People"), Groups("Groups"), Channels("Channels"), Archived("Archived");
    fun includes(c: ConversationEntity): Boolean = when (this) {
        Archived -> c.archived
        else -> !c.archived && when (this) {
            All -> c.kindEnum != ConversationKind.community
            Unread -> c.unread > 0 || c.markedUnread
            People -> c.kindEnum == ConversationKind.dm || c.kindEnum == ConversationKind.saved
            Groups -> c.kindEnum == ConversationKind.group
            Channels -> c.kindEnum == ConversationKind.channel
            else -> true
        }
    }
}

@Composable
private fun ChatListScreen(convs: List<ConversationEntity>, open: (String) -> Unit) {
    val engine = AsgardApp.engine
    var folderIndex by rememberSaveable { mutableStateOf(0) }
    val folders = Folder.entries.dropLast(1).map { FolderChoice(it) } + AsgardApp.prefs.customFolders.map { FolderChoice(null, it) } + FolderChoice(Folder.Archived)
    val folder = folders.getOrElse(folderIndex) { folders[0] }
    var search by rememberSaveable { mutableStateOf("") }
    var newChat by remember { mutableStateOf(false) }
    val voice by engine.voiceRooms.collectAsState()
    val typing by engine.typing.collectAsState()
    val visible = convs.filter { folder.includes(it) && (search.isBlank() || it.title.contains(search, true)) }
    var hits by remember { mutableStateOf<List<com.giantmushroom.asgardchat.data.MessageEntity>>(emptyList()) }
    LaunchedEffect(search) { kotlinx.coroutines.delay(200); hits = engine.searchMessages(search.trim()) }

    Box(Modifier.fillMaxSize()) {
        AuroraBackground(0.6f)
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 110.dp)) {
            item {
                Column(Modifier.statusBarsPadding().padding(horizontal = 16.dp)) {
                    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Spacer(Modifier.weight(1f))
                        IconButton({ newChat = true }, Modifier.glass(CircleShape)) { Icon(Icons.Filled.Edit, "New chat", tint = MaterialTheme.colorScheme.primary) }
                    }
                    Text("Chats", fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(vertical = 6.dp))
                    TextField(search, { search = it }, Modifier.fillMaxWidth().glass(RoundedCornerShape(22.dp)), singleLine = true,
                        placeholder = { Text("Search chats and messages") }, leadingIcon = { Icon(Icons.Filled.Search, null) },
                        colors = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent))
                    HistoryNudge(Modifier.padding(top = 10.dp))
                }
            }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(folders.size) { i ->
                        val f = folders[i]
                        val on = f == folder
                        Box(Modifier.clip(RoundedCornerShape(50)).then(if (on) Modifier.background(MaterialTheme.colorScheme.primary) else Modifier.glass(RoundedCornerShape(50)))
                            .clickable { folderIndex = i }.padding(horizontal = 14.dp, vertical = 7.dp)) {
                            Text(f.title, color = if (on) Color.White else MaterialTheme.colorScheme.onSurface, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal)
                        }
                    }
                }
            }
            items(visible, key = { it.id }) { c ->
                ChatRow(c, voice[c.id]?.size ?: 0, typing[c.id]?.keys?.firstOrNull()) { open(c.id) }
            }
            if (hits.isNotEmpty()) {
                item { Text("Messages", Modifier.padding(horizontal = 16.dp, vertical = 8.dp), fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(hits, key = { "m" + it.id }) { m ->
                    Column(Modifier.fillMaxWidth().clickable { open(m.conversationID) }.padding(horizontal = 16.dp, vertical = 8.dp)) {
                        Text(convs.firstOrNull { it.id == m.conversationID }?.title ?: "", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                        Text(m.content?.text ?: "", maxLines = 2, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        if (visible.isEmpty()) Text(if (search.isBlank()) "No chats yet" else "No results", Modifier.align(Alignment.Center), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (newChat) NewChatSheet({ newChat = false }) { open(it); newChat = false }
}

@Composable
private fun ChatRow(c: ConversationEntity, inVoice: Int, typingUser: String?, onClick: () -> Unit) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    val presence by engine.presence.collectAsState()
    var menu by remember { mutableStateOf(false) }
    val conv = c.conversation
    val peer = conv?.peer
    Box {
        Row(Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = { menu = true }).padding(horizontal = 16.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
            Avatar(peer?.id?.toString() ?: c.id, c.title, 56.dp, mediaID = (peer?.avatarMediaID ?: conv?.avatarMediaID)?.toString(),
                online = peer != null && (presence[peer.id.toString()] ?: peer.online), kind = c.kind)
            Column(Modifier.padding(start = 12.dp).weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                        Text(c.title.ifEmpty { "Chat" }, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        if (c.isMuted) Icon(Icons.Filled.NotificationsOff, null, Modifier.padding(start = 4.dp).size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (c.pinned) Icon(Icons.Filled.PushPin, null, Modifier.padding(start = 4.dp).size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (inVoice > 0) Row(Modifier.padding(end = 6.dp).clip(RoundedCornerShape(50)).background(Brand.teal).padding(horizontal = 6.dp, vertical = 1.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.VolumeUp, null, Modifier.size(12.dp), tint = Color.White)
                        Text(" $inVoice", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }
                    Text(stamp(c.previewDate ?: c.sortDate), fontSize = 13.sp,
                        color = if (c.unread > 0 && !c.isMuted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Row(verticalAlignment = Alignment.Top) {
                    val preview = when {
                        typingUser != null -> if (c.kindEnum == ConversationKind.dm) "typing…" else "${engine.name(typingUser)} is typing…"
                        c.draft.isNotEmpty() -> "Draft: ${c.draft}"
                        c.kindEnum != ConversationKind.dm && c.previewSenderID != null -> "${engine.name(c.previewSenderID)}: ${c.previewText}"
                        else -> c.previewText
                    }
                    Text(preview, color = if (typingUser != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 15.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    if (c.unread > 0) Box(Modifier.padding(start = 8.dp)) { Badge(c.unread, c.isMuted) }
                }
            }
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem({ Text(if (c.pinned) "Unpin" else "Pin") }, { menu = false; scope.launch { engine.setPrefs(c.id, pinned = !c.pinned) } })
            DropdownMenuItem({ Text(if (c.isMuted) "Unmute" else "Mute") }, {
                menu = false
                scope.launch { if (c.isMuted) engine.setPrefs(c.id, unmute = true) else engine.setPrefs(c.id, mutedUntil = Instant.now().plus(3650, ChronoUnit.DAYS)) }
            })
            DropdownMenuItem({ Text(if (c.archived) "Unarchive" else "Archive") }, { menu = false; scope.launch { engine.setPrefs(c.id, archived = !c.archived) } })
            DropdownMenuItem({ Text("Mark as read") }, { menu = false; engine.markRead(c.id) })
            if (AsgardApp.prefs.customFolders.isNotEmpty()) {
                DropdownMenuItem({ Text(if (c.folder.isEmpty()) "Move to folder:" else "In folder “${c.folder}”") }, {}, enabled = false)
                (listOf("") + AsgardApp.prefs.customFolders).forEach { f ->
                    DropdownMenuItem({ Text(if (f.isEmpty()) "   No folder" else "   $f") }, { menu = false; scope.launch { engine.setFolder(c.id, f) } })
                }
            }
        }
    }
}

fun stamp(ms: Long): String {
    val t = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault())
    val today = LocalDate.now()
    return when {
        t.toLocalDate() == today -> t.format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))
        t.toLocalDate() == today.minusDays(1) -> "Yesterday"
        t.toLocalDate().isAfter(today.minusDays(7)) -> t.format(DateTimeFormatter.ofPattern("EEEE"))
        else -> t.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT))
    }
}
