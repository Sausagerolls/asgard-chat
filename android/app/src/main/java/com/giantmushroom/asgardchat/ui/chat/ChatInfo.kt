package com.giantmushroom.asgardchat.ui.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.net.ConversationKind
import com.giantmushroom.asgardchat.net.Member
import com.giantmushroom.asgardchat.net.MemberRole
import com.giantmushroom.asgardchat.ui.components.AuroraBackground
import com.giantmushroom.asgardchat.ui.components.Avatar
import com.giantmushroom.asgardchat.ui.components.glass
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.temporal.ChronoUnit

/** Who's in the chat, mute, add people, leave. */
@Composable
fun ChatInfo(conversationID: String, back: () -> Unit) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    val conv by engine.dao.conversationFlow(conversationID).collectAsState(null)
    val presence by engine.presence.collectAsState()
    var members by remember { mutableStateOf<List<Member>>(emptyList()) }
    var adding by remember { mutableStateOf(false) }
    var confirmLeave by remember { mutableStateOf(false) }
    LaunchedEffect(conversationID) { members = engine.members(conversationID) }
    val c = conv?.conversation
    val kind = conv?.kindEnum
    val myRole = c?.me?.role ?: MemberRole.member
    val canManage = myRole == MemberRole.owner || myRole == MemberRole.admin

    Box(Modifier.fillMaxSize()) {
        AuroraBackground(0.5f)
        Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            IconButton(back, Modifier.glass(CircleShape)) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Avatar(c?.peer?.id?.toString() ?: conversationID, conv?.title ?: "", 96.dp, mediaID = (c?.peer?.avatarMediaID ?: c?.avatarMediaID)?.toString(), kind = conv?.kind)
                Text(conv?.title ?: "", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                c?.peer?.let { Text("@${it.username}", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                if (!c?.description.isNullOrBlank()) Text(c!!.description, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Lock, null, Modifier.padding(end = 4.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("End-to-end encrypted", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Row(Modifier.fillMaxWidth().glass().padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Mute notifications", Modifier.weight(1f))
                Switch(conv?.isMuted == true, { on ->
                    scope.launch { if (on) engine.setPrefs(conversationID, mutedUntil = Instant.now().plus(3650, ChronoUnit.DAYS)) else engine.setPrefs(conversationID, unmute = true) }
                })
            }
            if (kind == ConversationKind.group || kind == ConversationKind.channel) {
                Column(Modifier.glass().padding(vertical = 6.dp)) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("${c?.memberCount ?: members.size} members", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                        if (canManage || kind == ConversationKind.group) TextButton({ adding = true }) { Text("Add") }
                    }
                    members.forEach { m -> MemberRow(conversationID, m, canManage && m.role.ordinal < myRole.ordinal, presence[m.user.id.toString()] ?: m.user.online) {
                        scope.launch { members = engine.members(conversationID) }
                    } }
                }
            }
            if (kind != ConversationKind.dm && kind != ConversationKind.saved) TextButton({ confirmLeave = true }, Modifier.fillMaxWidth().glass()) {
                Text("Leave", color = MaterialTheme.colorScheme.error)
            }
            TextButton({ scope.launch { engine.clearHistory(conversationID) } }, Modifier.fillMaxWidth().glass()) {
                Text("Clear chat on this phone", color = MaterialTheme.colorScheme.error)
            }
        }
    }
    if (adding) AddPeopleSheet(members.map { it.user.id.toString() }.toSet(), { adding = false }) { ids ->
        adding = false
        scope.launch { runCatching { engine.addMembers(conversationID, ids) }; members = engine.members(conversationID) }
    }
    if (confirmLeave) AlertDialog({ confirmLeave = false }, confirmButton = {
        TextButton({ confirmLeave = false; scope.launch { runCatching { engine.leave(conversationID) }; back() } }) { Text("Leave", color = MaterialTheme.colorScheme.error) }
    }, dismissButton = { TextButton({ confirmLeave = false }) { Text("Cancel") } }, title = { Text("Leave ${conv?.title ?: "this chat"}?") })
}

@Composable
private fun MemberRow(conv: String, m: Member, manageable: Boolean, online: Boolean, changed: () -> Unit) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    val me = m.user.id.toString() == engine.myID
    Box {
        Row(Modifier.fillMaxWidth().clickable(enabled = manageable) { menu = true }.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Avatar(m.user.id.toString(), m.user.displayName, 36.dp, mediaID = m.user.avatarMediaID?.toString(), online = online)
            Column(Modifier.padding(start = 10.dp).weight(1f)) {
                Text(if (me) "You" else m.user.displayName)
                if (m.role != MemberRole.member && m.role != MemberRole.subscriber) Text(m.role.name.replaceFirstChar { it.uppercase() }, fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        DropdownMenu(menu, { menu = false }) {
            listOf(MemberRole.member, MemberRole.moderator, MemberRole.admin).forEach { r ->
                DropdownMenuItem({ Text("Make ${r.name}") }, {
                    menu = false
                    scope.launch {
                        runCatching { engine.api!!.call("PATCH", "/conversations/$conv/members/${m.user.id}", kotlinx.serialization.json.buildJsonObject {
                            put("role", kotlinx.serialization.json.JsonPrimitive(r.name)) }) }
                        changed()
                    }
                })
            }
            DropdownMenuItem({ Text("Remove", color = MaterialTheme.colorScheme.error) }, {
                menu = false
                scope.launch { runCatching { engine.removeMember(conv, m.user.id.toString()) }; changed() }
            })
        }
    }
}
