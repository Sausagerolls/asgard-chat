package com.giantmushroom.asgardchat.ui.calls

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.engine.IncomingCall
import com.giantmushroom.asgardchat.net.ApiError
import com.giantmushroom.asgardchat.ui.components.AuroraBackground
import com.giantmushroom.asgardchat.ui.components.Avatar
import com.giantmushroom.asgardchat.ui.components.glass
import com.giantmushroom.asgardchat.ui.main.stamp
import com.giantmushroom.asgardchat.ui.theme.Brand
import io.livekit.android.LiveKit
import io.livekit.android.RoomOptions
import io.livekit.android.e2ee.BaseKeyProvider
import io.livekit.android.e2ee.E2EEOptions
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.renderer.TextureViewRenderer
import io.livekit.android.room.Room
import io.livekit.android.room.participant.Participant
import io.livekit.android.room.track.Track
import io.livekit.android.room.track.VideoTrack
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.util.Base64

/** One call or voice room this phone is in. */
class ActiveCall(val conversationID: String, val title: String, val voiceRoom: Boolean, val outgoing: Boolean, video: Boolean) {
    var muted by mutableStateOf(false)
    var cameraOn by mutableStateOf(video)
    var connectedAt by mutableLongStateOf(0L)
    var state by mutableStateOf("Connecting…")
    var revision by mutableIntStateOf(0)
    var expanded by mutableStateOf(true)
    var room: Room? = null
}

/**
 * Calls and voice rooms. Same server flow and end-to-end media encryption as
 * iPhone and Mac: the room key is shared as a base64 string so every
 * platform's LiveKit derives the same frame key.
 */
object Calls {
    val active = MutableStateFlow<ActiveCall?>(null)
    private val engine get() = AsgardApp.engine
    private var heartbeat: Job? = null
    private var events: Job? = null

    fun start(conv: String, video: Boolean) = launch(conv, voiceRoom = false, video = video)
    fun joinVoice(conv: String, video: Boolean) {
        if (active.value?.let { it.voiceRoom && it.conversationID == conv } == true) { active.value?.expanded = true; return }
        launch(conv, voiceRoom = true, video = video)
    }

    private fun launch(conv: String, voiceRoom: Boolean, video: Boolean, outgoing: Boolean = true) {
        engine.scope.launch {
            active.value?.let { hangUp() }
            val title = engine.dao.conversation(conv)?.title ?: "Call"
            val call = ActiveCall(conv, title, voiceRoom, outgoing, video)
            active.value = call
            connect(call)
        }
    }

    fun accept(c: IncomingCall, video: Boolean) {
        engine.incomingCall.value = null
        AsgardApp.notifier.cancelCall()
        engine.scope.launch {
            active.value?.let { hangUp() }
            val call = ActiveCall(c.conversationID.toString(), engine.dao.conversation(c.conversationID.toString())?.title ?: c.callerName, false, false, video && c.video)
            active.value = call
            connect(call)
        }
    }

    fun decline(c: IncomingCall) {
        engine.incomingCall.value = null
        AsgardApp.notifier.cancelCall()
        engine.scope.launch {
            val dm = engine.dao.conversation(c.conversationID.toString())?.kind == "dm"
            engine.endCall(c.conversationID.toString(), "declined", dm)
            engine.recordCall(c.conversationID.toString(), c.video, outgoing = false, durationMs = 0, missed = true)
        }
    }

    private suspend fun connect(call: ActiveCall) {
        try {
            val url: String; val token: String; val key: ByteArray?
            if (call.voiceRoom) {
                val (join, k) = engine.joinVoice(call.conversationID, call.muted, call.cameraOn)
                url = join.url; token = join.token; key = k
            } else {
                val join = engine.startCall(call.conversationID, call.cameraOn)
                url = join.url; token = join.token
                var k: ByteArray? = null
                repeat(30) { if (k == null) { k = engine.callKeys[join.room]; if (k == null) { engine.syncNow(); delay(150) } } }
                key = k
            }
            if (key == null) throw ApiError(0, "no_room_key", "Couldn't get the call's encryption key. Try again in a moment.")
            val provider = BaseKeyProvider()
            provider.enableSharedKey = true
            provider.setSharedKey(Base64.getEncoder().encodeToString(key), null)
            val room = LiveKit.create(AsgardApp.instance, RoomOptions(adaptiveStream = true, dynacast = true, e2eeOptions = E2EEOptions(keyProvider = provider)))
            call.room = room
            events = engine.scope.launch {
                room.events.collect { e ->
                    call.revision++
                    if (room.remoteParticipants.isNotEmpty() && call.connectedAt == 0L) { call.connectedAt = System.currentTimeMillis(); call.state = "Connected" }
                    if (e is RoomEvent.ParticipantDisconnected && !call.voiceRoom && room.remoteParticipants.isEmpty() && call.connectedAt > 0 &&
                        engine.dao.conversation(call.conversationID)?.kind == "dm") hangUp()
                }
            }
            room.connect(url, token)
            room.localParticipant.setMicrophoneEnabled(!call.muted)
            if (call.cameraOn) room.localParticipant.setCameraEnabled(true)
            if (call.voiceRoom || room.remoteParticipants.isNotEmpty()) { call.connectedAt = System.currentTimeMillis(); call.state = "Connected" } else call.state = "Ringing…"
            if (call.voiceRoom) heartbeat = engine.scope.launch { while (true) { delay(30_000); engine.updateVoice(call.conversationID) } }
            com.giantmushroom.asgardchat.notify.CallService.start(AsgardApp.instance, call.title, call.cameraOn)
        } catch (e: Throwable) {
            engine.banner.value = (e as? ApiError)?.message ?: "Couldn't connect."
            teardown(call, notify = true)
        }
    }

    fun toggleMute() {
        val c = active.value ?: return
        c.muted = !c.muted
        engine.scope.launch {
            c.room?.localParticipant?.setMicrophoneEnabled(!c.muted)
            if (c.voiceRoom) engine.updateVoice(c.conversationID, muted = c.muted)
        }
    }

    fun toggleCamera() {
        val c = active.value ?: return
        c.cameraOn = !c.cameraOn
        engine.scope.launch {
            c.room?.localParticipant?.setCameraEnabled(c.cameraOn)
            if (c.voiceRoom) engine.updateVoice(c.conversationID, video = c.cameraOn)
        }
    }

    suspend fun hangUp() { active.value?.let { teardown(it, notify = true) } }

    fun remoteEnded(conv: String) {
        val c = active.value ?: return
        if (!c.voiceRoom && c.conversationID == conv) engine.scope.launch { teardown(c, notify = false) }
    }

    private suspend fun teardown(call: ActiveCall, notify: Boolean) {
        heartbeat?.cancel(); events?.cancel()
        call.room?.disconnect()
        call.room?.release()
        val duration = if (call.connectedAt > 0) System.currentTimeMillis() - call.connectedAt else 0
        if (call.voiceRoom) engine.leaveVoice(call.conversationID)
        else {
            if (notify) engine.endCall(call.conversationID, "hangup", engine.dao.conversation(call.conversationID)?.kind == "dm")
            engine.recordCall(call.conversationID, call.cameraOn, call.outgoing, duration, missed = false)
        }
        if (active.value === call) active.value = null
        AsgardApp.notifier.cancelCall()
        com.giantmushroom.asgardchat.notify.CallService.stop(AsgardApp.instance)
    }
}

@Composable
private fun rememberMediaPermissions(onGranted: (Boolean) -> Unit): (Boolean) -> Unit {
    val ctx = LocalContext.current
    var pendingVideo by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        if (res[Manifest.permission.RECORD_AUDIO] == true) onGranted(pendingVideo && res[Manifest.permission.CAMERA] == true)
    }
    return { video ->
        pendingVideo = video
        val need = listOf(Manifest.permission.RECORD_AUDIO) + if (video) listOf(Manifest.permission.CAMERA) else emptyList()
        if (need.all { ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED }) onGranted(video) else launcher.launch(need.toTypedArray())
    }
}

/** Always-visible strip in groups and channels: who's in the voice room, and Join. */
@Composable
fun VoiceRoomBar(conversationID: String, modifier: Modifier = Modifier) {
    val engine = AsgardApp.engine
    val rooms by engine.voiceRooms.collectAsState()
    val active by Calls.active.collectAsState()
    val people = rooms[conversationID] ?: emptyList()
    val inRoom = active?.let { it.voiceRoom && it.conversationID == conversationID } == true
    val ask = rememberMediaPermissions { video -> Calls.joinVoice(conversationID, video) }
    LaunchedEffect(conversationID) { engine.refreshVoiceRoom(conversationID) }
    Row(modifier.fillMaxWidth().glass(RoundedCornerShape(22.dp), tint = if (inRoom) Brand.teal else Color.Unspecified).padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.VolumeUp, null, tint = if (people.isEmpty()) MaterialTheme.colorScheme.onSurfaceVariant else Brand.teal, modifier = Modifier.size(20.dp))
        Column(Modifier.padding(start = 10.dp).weight(1f)) {
            Text("Voice room", fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            Text(when (people.size) {
                0 -> "Nobody's here. Drop in any time."
                1 -> "${people[0].name} is here"
                2 -> "${people[0].name} and ${people[1].name}"
                else -> "${people[0].name} and ${people.size - 1} others"
            }, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        Row(horizontalArrangement = Arrangement.spacedBy((-8).dp)) {
            people.take(4).forEach { Avatar(it.userID.toString(), it.name, 26.dp, modifier = Modifier.border(2.dp, MaterialTheme.colorScheme.background, CircleShape)) }
        }
        Spacer(Modifier.size(8.dp))
        if (inRoom) Button({ AsgardApp.engine.scope.launch { Calls.hangUp() } }, colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFE5484D))) { Text("Leave") }
        else Button({ ask(false) }, colors = ButtonDefaults.buttonColors(containerColor = Brand.teal)) { Text("Join", color = Color.White) }
    }
}

/** Full-screen call UI, a minimised pill, and the incoming call sheet. */
@Composable
fun CallOverlay() {
    val engine = AsgardApp.engine
    val call by Calls.active.collectAsState()
    val ringing by engine.incomingCall.collectAsState()
    LaunchedEffect(Unit) { engine.callEnded.collect { Calls.remoteEnded(it.toString()) } }
    val askAccept = rememberMediaPermissions { video -> ringing?.let { Calls.accept(it, video) } }

    ringing?.takeIf { call == null }?.let { r ->
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f)).clickable(enabled = false) {}, contentAlignment = Alignment.Center) {
            Column(Modifier.padding(24.dp).glass(RoundedCornerShape(32.dp), strong = true).padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Avatar(r.callerID.toString(), r.callerName, 88.dp, mediaID = engine.user(r.callerID.toString())?.avatarMediaID?.toString())
                Text(r.callerName, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Text(if (r.video) "Incoming video call" else "Incoming call", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    RoundButton(Icons.Filled.CallEnd, Color(0xFFE5484D)) { Calls.decline(r) }
                    if (r.video) RoundButton(Icons.Filled.Videocam, Brand.teal) { askAccept(true) }
                    RoundButton(Icons.Filled.Call, Color(0xFF30D158)) { askAccept(false) }
                }
            }
        }
    }

    val c = call ?: return
    AnimatedVisibility(c.expanded, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) { CallScreen(c) }
    if (!c.expanded) {
        Box(Modifier.fillMaxSize().statusBarsPadding().padding(top = 4.dp), contentAlignment = Alignment.TopCenter) {
            Row(Modifier.glass(RoundedCornerShape(50), tint = Brand.teal).clickable { c.expanded = true }.padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(if (c.voiceRoom) Icons.Filled.VolumeUp else Icons.Filled.Call, null, Modifier.size(16.dp), tint = Color.White)
                Text("  ${c.title} · ${elapsed(c)}", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            }
        }
    }
}

@Composable
private fun elapsed(c: ActiveCall): String {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    if (c.connectedAt == 0L) return c.state
    val s = (now - c.connectedAt) / 1000
    return "%d:%02d".format(s / 60, s % 60)
}

@Composable
private fun CallScreen(c: ActiveCall) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    Box(Modifier.fillMaxSize()) {
        AuroraBackground(0.9f)
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton({ c.expanded = false }, Modifier.glass(CircleShape)) { Icon(Icons.Filled.KeyboardArrowDown, "Minimise") }
                Column(Modifier.padding(start = 12.dp)) {
                    Text(c.title, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                    Text("${elapsed(c)} · End-to-end encrypted", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            val room = c.room
            @Suppress("UNUSED_VARIABLE") val rev = c.revision
            val tiles = buildList<Pair<Participant, Boolean>> {
                room?.remoteParticipants?.values?.forEach { add(it to false) }
                room?.localParticipant?.let { add(it to true) }
            }
            LazyVerticalGrid(GridCells.Fixed(if (tiles.size <= 1) 1 else 2), Modifier.weight(1f).padding(horizontal = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(tiles, key = { (p, _) -> p.sid.value }) { (p, me) ->
                    val video = p.videoTrackPublications.firstOrNull { (pub, _) -> !pub.muted }?.second as? VideoTrack
                    Box(Modifier.aspectRatio(if (tiles.size <= 2) 0.75f else 1f).clip(RoundedCornerShape(20.dp)).background(Color.Black.copy(alpha = 0.3f))
                        .border(if (p.isSpeaking) 3.dp else 0.dp, Brand.teal, RoundedCornerShape(20.dp))) {
                        if (video != null && room != null) VideoView(room, video, me)
                        else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            val uid = p.identity?.value?.substringBefore(":")
                            val user = engine.user(uid)
                            Avatar(uid, user?.displayName ?: p.name ?: "?", 88.dp, mediaID = user?.avatarMediaID?.toString())
                        }
                        Text(if (me) "You" else p.name ?: "", Modifier.align(Alignment.BottomStart).padding(8.dp).clip(RoundedCornerShape(50))
                            .background(Color.Black.copy(alpha = 0.45f)).padding(horizontal = 8.dp, vertical = 3.dp), color = Color.White, fontSize = 12.sp)
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(20.dp), horizontalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterHorizontally)) {
                RoundButton(if (c.muted) Icons.Filled.MicOff else Icons.Filled.Mic, if (c.muted) Color.White else Color.White.copy(alpha = 0.15f),
                    tint = if (c.muted) Color.Black else Color.White) { Calls.toggleMute() }
                RoundButton(if (c.cameraOn) Icons.Filled.Videocam else Icons.Filled.VideocamOff, if (!c.cameraOn) Color.White else Color.White.copy(alpha = 0.15f),
                    tint = if (!c.cameraOn) Color.Black else Color.White) { Calls.toggleCamera() }
                RoundButton(Icons.Filled.CallEnd, Color(0xFFE5484D)) { scope.launch { Calls.hangUp() } }
            }
        }
    }
}

@Composable
private fun VideoView(room: Room, track: VideoTrack, mirror: Boolean) {
    var renderer by remember { mutableStateOf<TextureViewRenderer?>(null) }
    AndroidView(factory = { ctx -> TextureViewRenderer(ctx).also { room.initVideoRenderer(it); it.setMirror(mirror); renderer = it } }, modifier = Modifier.fillMaxSize())
    DisposableEffect(track, renderer) {
        val r = renderer
        r?.let { track.addRenderer(it) }
        onDispose { r?.let { track.removeRenderer(it) } }
    }
}

@Composable
private fun RoundButton(icon: androidx.compose.ui.graphics.vector.ImageVector, color: Color, tint: Color = Color.White, onClick: () -> Unit) {
    Box(Modifier.size(64.dp).clip(CircleShape).background(color).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(28.dp))
    }
}

@Composable
fun CallsTab(openChat: (String) -> Unit) {
    val engine = AsgardApp.engine
    val calls by engine.dao.calls().collectAsState(emptyList())
    val convs by engine.dao.conversations().collectAsState(emptyList())
    Box(Modifier.fillMaxSize()) {
        AuroraBackground(0.5f)
        LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 110.dp)) {
            item { Text("Calls", fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(16.dp)) }
            items(calls, key = { it.id }) { c ->
                val conv = convs.firstOrNull { it.id == c.conversationID }
                Row(Modifier.fillMaxWidth().clickable { openChat(c.conversationID) }.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Avatar(conv?.conversation?.peer?.id?.toString() ?: c.conversationID, conv?.title ?: "?", 46.dp, kind = conv?.kind)
                    Column(Modifier.padding(start = 12.dp).weight(1f)) {
                        Text(conv?.title ?: "Unknown", fontWeight = FontWeight.SemiBold, color = if (c.missed) Color(0xFFFF6B6B) else MaterialTheme.colorScheme.onSurface)
                        Text((if (c.missed) "Missed" else if (c.outgoing) "Outgoing" else "Incoming") +
                            if (c.duration > 0) " · ${c.duration / 60000} min ${(c.duration / 1000) % 60} sec" else "", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(stamp(c.startedAt), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    IconButton({ Calls.start(c.conversationID, c.video) }) { Icon(if (c.video) Icons.Filled.Videocam else Icons.Filled.Call, "Call", tint = MaterialTheme.colorScheme.primary) }
                }
            }
        }
        if (calls.isEmpty()) Text("No calls yet", Modifier.align(Alignment.Center), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
