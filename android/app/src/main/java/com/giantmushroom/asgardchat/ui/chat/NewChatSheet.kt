package com.giantmushroom.asgardchat.ui.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.net.ApiError
import com.giantmushroom.asgardchat.net.ConversationKind
import com.giantmushroom.asgardchat.net.User
import com.giantmushroom.asgardchat.ui.components.Avatar
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewChatSheet(dismiss: () -> Unit, opened: (String) -> Unit) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    var kind by remember { mutableStateOf(0) }
    var query by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<User>>(emptyList()) }
    val picked = remember { mutableStateListOf<User>() }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(query) { delay(200); results = engine.searchUsers(query).filter { it.id.toString().lowercase() != engine.myID } }

    ModalBottomSheet(dismiss) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf("Message", "Group", "Channel").forEachIndexed { i, t -> SegmentedButton(kind == i, { kind = i }, SegmentedButtonDefaults.itemShape(i, 3)) { Text(t) } }
            }
            if (kind != 0) OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text(if (kind == 1) "Group name" else "Channel name") }, singleLine = true)
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), label = { Text("Search people") }, singleLine = true)
            LazyColumn(Modifier.heightIn(max = 360.dp)) {
                items(results, key = { it.id }) { u ->
                    Row(Modifier.fillMaxWidth().clickable {
                        if (kind == 0) scope.launch { runCatching { engine.openDM(u.id.toString()) }.onSuccess(opened).onFailure { error = (it as? ApiError)?.message } }
                        else if (picked.any { it.id == u.id }) picked.removeAll { it.id == u.id } else picked += u
                    }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Avatar(u.id.toString(), u.displayName, 40.dp, mediaID = u.avatarMediaID?.toString())
                        Column(Modifier.padding(start = 12.dp).weight(1f)) {
                            Text(u.displayName, fontWeight = FontWeight.SemiBold)
                            Text("@${u.username}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (kind != 0) Checkbox(picked.any { it.id == u.id }, null)
                    }
                }
            }
            if (kind != 0) Button({
                scope.launch {
                    runCatching { engine.create(if (kind == 1) ConversationKind.group else ConversationKind.channel, name.trim(), picked.map { it.id.toString() }) }
                        .onSuccess(opened).onFailure { error = (it as? ApiError)?.message ?: it.message }
                }
            }, Modifier.fillMaxWidth(), enabled = name.isNotBlank()) { Text("Create (${picked.size} people)") }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}

/** Picks people to add to a group or channel. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddPeopleSheet(exclude: Set<String>, dismiss: () -> Unit, done: (List<String>) -> Unit) {
    val engine = AsgardApp.engine
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<User>>(emptyList()) }
    val picked = remember { mutableStateListOf<String>() }
    LaunchedEffect(query) { delay(200); results = engine.searchUsers(query).filter { it.id.toString() !in exclude && it.id.toString() != engine.myID } }
    ModalBottomSheet(dismiss) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), label = { Text("Search people") }, singleLine = true)
            LazyColumn(Modifier.heightIn(max = 360.dp)) {
                items(results, key = { it.id }) { u ->
                    val id = u.id.toString()
                    Row(Modifier.fillMaxWidth().clickable { if (id in picked) picked.remove(id) else picked += id }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Avatar(id, u.displayName, 40.dp, mediaID = u.avatarMediaID?.toString())
                        Text(u.displayName, Modifier.padding(start = 12.dp).weight(1f))
                        Checkbox(id in picked, null)
                    }
                }
            }
            Button({ done(picked.toList()) }, Modifier.fillMaxWidth(), enabled = picked.isNotEmpty()) { Text("Add ${picked.size}") }
        }
    }
}
