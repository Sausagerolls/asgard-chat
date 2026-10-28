package com.giantmushroom.asgardchat.ui.main

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.net.User
import com.giantmushroom.asgardchat.ui.calls.Calls
import com.giantmushroom.asgardchat.ui.components.Avatar
import com.giantmushroom.asgardchat.ui.components.AuroraBackground
import com.giantmushroom.asgardchat.ui.components.glass
import kotlinx.coroutines.launch

/** Everyone on the server, favourites first, with one-tap message and call buttons. */
@Composable
fun PeopleTab(openChat: (String) -> Unit) {
    val engine = AsgardApp.engine
    val me by engine.me.collectAsState()
    val info by engine.serverInfo.collectAsState()
    val scope = rememberCoroutineScope()
    var people by remember { mutableStateOf<List<User>>(emptyList()) }
    var search by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { people = engine.searchUsers("").filter { !it.isBot && it.id != me?.id } }
    val favs = engine.favoriteIds(me)
    val shown = people.filter { search.isBlank() || it.displayName.contains(search, true) || it.username.contains(search, true) }
    val favourites = shown.filter { it.id.toString() in favs }
    val others = shown.filter { it.id.toString() !in favs }
    val callsOn = info?.features?.calls != false

    fun dm(u: User, then: (String) -> Unit) = scope.launch {
        runCatching { engine.openDM(u.id.toString()) }.onSuccess(then).onFailure { error = it.message ?: "Check your connection and try again." }
    }

    Box(Modifier.fillMaxSize()) {
        AuroraBackground(0.5f)
        LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = PaddingValues(bottom = 110.dp)) {
            item { Text("People", fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(16.dp)) }
            item {
                OutlinedTextField(search, { search = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp), placeholder = { Text("Search people") }, singleLine = true)
            }
            error?.let { item { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp)) } }
            if (favourites.isNotEmpty()) {
                item { Header("Favourites") }
                items(favourites, key = { "f" + it.id.toString() }) { Person(it, true, callsOn, { on -> scope.launch { engine.setFavorite(it.id.toString(), on) } },
                    { dm(it, openChat) }, { video -> dm(it) { c -> Calls.start(c, video) } }) }
            }
            if (others.isNotEmpty()) {
                if (favourites.isNotEmpty()) item { Header("Everyone") }
                items(others, key = { "o" + it.id.toString() }) { Person(it, false, callsOn, { on -> scope.launch { engine.setFavorite(it.id.toString(), on) } },
                    { dm(it, openChat) }, { video -> dm(it) { c -> Calls.start(c, video) } }) }
            }
            if (shown.isEmpty()) item {
                Text(if (search.isBlank()) "No one else here yet. Invite people from Server admin." else "No matches",
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(24.dp))
            }
        }
    }
}

@Composable
private fun Header(title: String) =
    Text(title, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 20.dp, top = 18.dp, bottom = 6.dp))

@Composable
private fun Person(u: User, favourite: Boolean, callsOn: Boolean, setFavourite: (Boolean) -> Unit, message: () -> Unit, call: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).glass().padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Avatar(u.id.toString(), u.displayName, 44.dp, mediaID = u.avatarMediaID?.toString(), online = u.online)
        Column(Modifier.padding(start = 12.dp).weight(1f)) {
            Text(u.displayName, fontWeight = FontWeight.SemiBold, maxLines = 1)
            Text(if (u.online) "Online" else "@${u.username}", fontSize = 13.sp, maxLines = 1,
                color = if (u.online) Color(0xFF34C759) else MaterialTheme.colorScheme.onSurfaceVariant)
        }
        IconButton({ setFavourite(!favourite) }) {
            Icon(if (favourite) Icons.Filled.Star else Icons.Filled.StarBorder, if (favourite) "Remove from favourites" else "Add to favourites",
                tint = if (favourite) Color(0xFFFFCC00) else MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Action(Icons.AutoMirrored.Filled.Chat, "Message ${u.displayName}", message)
        if (callsOn) {
            Action(Icons.Filled.Call, "Call ${u.displayName}") { call(false) }
            Action(Icons.Filled.Videocam, "Video call ${u.displayName}") { call(true) }
        }
    }
}

@Composable
private fun Action(icon: ImageVector, label: String, onClick: () -> Unit) {
    IconButton(onClick, Modifier.padding(start = 2.dp).size(40.dp).background(MaterialTheme.colorScheme.primary.copy(alpha = 0.18f), CircleShape)) {
        Icon(icon, label, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
    }
}
