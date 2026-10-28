package com.giantmushroom.asgardchat.ui.chat

import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Poll
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.TextButton
import androidx.core.content.ContextCompat
import android.Manifest
import android.content.pm.PackageManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.data.MessageEntity
import com.giantmushroom.asgardchat.data.MessageStatus
import com.giantmushroom.asgardchat.engine.ChatEngine
import com.giantmushroom.asgardchat.engine.OutgoingFile
import com.giantmushroom.asgardchat.engine.SystemText
import com.giantmushroom.asgardchat.net.AsgardJson
import com.giantmushroom.asgardchat.net.ConversationKind
import com.giantmushroom.asgardchat.net.MemberRole
import com.giantmushroom.asgardchat.net.MessageContent
import com.giantmushroom.asgardchat.ui.calls.Calls
import com.giantmushroom.asgardchat.ui.calls.VoiceRoomBar
import com.giantmushroom.asgardchat.ui.components.AuroraBackground
import com.giantmushroom.asgardchat.ui.components.Avatar
import com.giantmushroom.asgardchat.ui.components.glass
import com.giantmushroom.asgardchat.ui.theme.BubbleStyle
import com.giantmushroom.asgardchat.ui.theme.LocalAppearance
import com.giantmushroom.asgardchat.ui.theme.identityColor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlin.math.abs

@Composable
fun ChatScreen(conversationID: String, back: () -> Unit) {
    val engine = AsgardApp.engine
    val conv by engine.dao.conversationFlow(conversationID).collectAsState(null)
    val info by engine.serverInfo.collectAsState()
    val callsOn = info?.features?.calls != false
    // null until the database answers, so "already here" and "just arrived" can be told apart.
    val loaded by remember(conversationID) { engine.dao.messages(conversationID) }.collectAsState(null)
    val messages = loaded ?: emptyList()
    val typing by engine.typing.collectAsState()
    var replyTo by remember { mutableStateOf<MessageEntity?>(null) }
    var editing by remember { mutableStateOf<MessageEntity?>(null) }
    var showInfo by remember { mutableStateOf(false) }
    val kind = conv?.kindEnum ?: ConversationKind.group
    if (showInfo) { ChatInfo(conversationID) { showInfo = false }; androidx.activity.compose.BackHandler { showInfo = false }; return }

    DisposableEffect(conversationID) {
        engine.activeConversation = conversationID
        engine.markRead(conversationID)
        onDispose { if (engine.activeConversation == conversationID) engine.activeConversation = null }
    }
    LaunchedEffect(messages.size) { engine.markRead(conversationID); AsgardApp.notifier.clear(conversationID) }

    Box(Modifier.fillMaxSize()) {
        com.giantmushroom.asgardchat.ui.components.ChatWallpaper(LocalAppearance.current.wallpaper)
        Column(Modifier.fillMaxSize().imePadding()) {
            // Glass header: back, title pill, call buttons.
            Row(Modifier.statusBarsPadding().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(back, Modifier.glass(CircleShape)) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                Box(Modifier.weight(1f).padding(start = 10.dp)) {
                Row(Modifier.glass(RoundedCornerShape(50)).clickable { showInfo = true }.padding(horizontal = 8.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    val peer = conv?.conversation?.peer
                    Avatar(peer?.id?.toString() ?: conversationID, conv?.title ?: "", 32.dp, mediaID = (peer?.avatarMediaID ?: conv?.conversation?.avatarMediaID)?.toString(), kind = conv?.kind)
                    Column(Modifier.padding(start = 8.dp, end = 6.dp)) {
                        Text(conv?.title ?: "", fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        val t = typing[conversationID]?.keys?.firstOrNull()
                        Text(when {
                            t != null -> if (kind == ConversationKind.dm) "typing…" else "${engine.name(t)} is typing…"
                            kind == ConversationKind.dm -> ""
                            kind == ConversationKind.channel -> "${conv?.conversation?.memberCount ?: 0} subscribers"
                            else -> "${conv?.conversation?.memberCount ?: 0} members"
                        }, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                }
                }
                if (kind == ConversationKind.dm && callsOn) Row(Modifier.padding(start = 8.dp).glass(RoundedCornerShape(50))) {
                    IconButton({ Calls.start(conversationID, video = true) }) { Icon(Icons.Filled.Videocam, "Video call", tint = MaterialTheme.colorScheme.primary) }
                    IconButton({ Calls.start(conversationID, video = false) }) { Icon(Icons.Filled.Call, "Voice call", tint = MaterialTheme.colorScheme.primary) }
                }
            }
            if (kind.hasVoiceRoom && callsOn) VoiceRoomBar(conversationID, Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
            MessageList(messages, loaded != null, kind, Modifier.weight(1f), onReply = { replyTo = it }, onEdit = { editing = it })
            val canPost = kind != ConversationKind.channel || conv?.conversation?.me?.role.let { it == MemberRole.owner || it == MemberRole.admin }
            if (canPost) Composer(conversationID, replyTo, editing, conv?.draft ?: "") { replyTo = null; editing = null }
            else Text("Only admins post here. React, vote, or join the voice room.", Modifier.navigationBarsPadding().padding(16.dp).fillMaxWidth(),
                color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
        }
    }
}

@Composable
private fun MessageList(messages: List<MessageEntity>, loaded: Boolean, kind: ConversationKind, modifier: Modifier, onReply: (MessageEntity) -> Unit, onEdit: (MessageEntity) -> Unit) {
    val engine = AsgardApp.engine
    val state = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val animate = LocalAppearance.current.messageAnimations
    val opened = remember { System.currentTimeMillis() }
    val initial = remember { mutableStateOf<Set<String>?>(null) }
    val played = remember { mutableSetOf<String>() }
    LaunchedEffect(loaded) { if (initial.value == null && loaded) initial.value = messages.map { it.clientID }.toSet() }
    // Newest at the bottom: the list is reversed so it starts there.
    val rows = remember(messages) { messages.asReversed() }
    val atBottom by remember { derivedStateOf { state.firstVisibleItemIndex <= 1 } }
    LaunchedEffect(messages.lastOrNull()?.clientID) {
        val last = messages.lastOrNull() ?: return@LaunchedEffect
        if (atBottom || last.senderUserID == engine.myID) state.animateScrollToItem(0)
    }
    // Scroll speed drives a gentle spread between bubbles that springs back, like iOS.
    val stretch = remember { Animatable(0f) }
    val flow = remember(animate) {
        object : androidx.compose.ui.input.nestedscroll.NestedScrollConnection {
            override fun onPostScroll(consumed: androidx.compose.ui.geometry.Offset, available: androidx.compose.ui.geometry.Offset,
                                      source: androidx.compose.ui.input.nestedscroll.NestedScrollSource): androidx.compose.ui.geometry.Offset {
                if (animate && consumed.y != 0f) scope.launch(FullMotion) {
                    stretch.snapTo((stretch.value * 0.6f - consumed.y * 0.35f).coerceIn(-18f, 18f))
                    stretch.animateTo(0f, spring(0.55f, Spring.StiffnessLow))
                }
                return androidx.compose.ui.geometry.Offset.Zero
            }
        }
    }

    Box(modifier) {
        LazyColumn(Modifier.fillMaxSize().nestedScroll(flow).softEdges(), state = state, reverseLayout = true,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp)) {
            itemsIndexed(rows, key = { _, m -> m.clientID }) { i, m ->
                val older = rows.getOrNull(i + 1)
                val newer = rows.getOrNull(i - 1)
                val first = older == null || !joins(older, m)
                val last = newer == null || !joins(m, newer)
                val arriving = animate && initial.value?.let { m.clientID !in it && m.sentAt > opened - 2000 && played.add(m.clientID) } == true
                Column {
                    if (older == null || !sameDay(older.sentAt, m.sentAt)) DaySeparator(m.sentAt)
                    MessageRow(m, kind != ConversationKind.dm && kind != ConversationKind.saved, first, last, arriving, stretch.value, i, onReply, onEdit)
                }
            }
        }
        AnimatedVisibility(!atBottom, Modifier.align(Alignment.BottomEnd).padding(16.dp), enter = scaleIn(), exit = scaleOut()) {
            IconButton({ scope.launch { state.animateScrollToItem(0) } }, Modifier.glass(CircleShape)) { Icon(Icons.Filled.KeyboardArrowDown, "Latest") }
        }
    }
}

private fun joins(a: MessageEntity, b: MessageEntity) = !a.isSystem && !b.isSystem && a.senderUserID == b.senderUserID && b.sentAt - a.sentAt < 180_000

private fun sameDay(a: Long, b: Long) = Instant.ofEpochMilli(a).atZone(ZoneId.systemDefault()).toLocalDate() == Instant.ofEpochMilli(b).atZone(ZoneId.systemDefault()).toLocalDate()

@Composable
private fun DaySeparator(ms: Long) {
    val d = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).toLocalDate()
    val text = when (d) { LocalDate.now() -> "Today"; LocalDate.now().minusDays(1) -> "Yesterday"; else -> d.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.FULL)) }
    Box(Modifier.fillMaxWidth().padding(vertical = 10.dp), contentAlignment = Alignment.Center) {
        Text(text, Modifier.glass(RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 4.dp), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageRow(m: MessageEntity, isGroup: Boolean, first: Boolean, last: Boolean, arriving: Boolean, stretch: Float, index: Int,
                       onReply: (MessageEntity) -> Unit, onEdit: (MessageEntity) -> Unit) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    val mine = m.senderUserID == engine.myID
    var menu by remember { mutableStateOf(false) }
    // Arrival: yours rise from the composer, theirs spring in from the left.
    val progress = remember { Animatable(if (arriving) 0f else 1f) }
    LaunchedEffect(Unit) { if (progress.value < 1f) withContext(FullMotion) { progress.animateTo(1f, spring(0.7f, Spring.StiffnessMediumLow)) } }

    if (m.isSystem) {
        val sys = remember(m.systemJson) { AsgardJson.parseToJsonElement(m.systemJson!!) }
        Box(Modifier.fillMaxWidth().padding(vertical = 4.dp), contentAlignment = Alignment.Center) {
            Text(SystemText.describe(sys) { engine.name(it) }, Modifier.glass(RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 4.dp),
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    val p = progress.value
    val drag = remember { Animatable(0f) }
    Row(Modifier.fillMaxWidth().padding(top = if (first) 6.dp else 1.dp)
        .pointerInput(m.id) {
            detectHorizontalDragGestures(onDragEnd = {
                if (drag.value > 120f) onReply(m)
                scope.launch { drag.animateTo(0f, spring(0.6f)) }
            }) { _, d -> scope.launch { drag.snapTo((drag.value + d).coerceIn(0f, 180f)) } }
        }
        .graphicsLayer {
            val s = 0.55f + 0.45f * p
            scaleX = s; scaleY = s
            transformOrigin = if (mine) TransformOrigin(1f, 1f) else TransformOrigin(0f, 1f)
            translationX = if (mine) 0f else -36f * (1 - p)
            // Bubbles further from the newest one move more, so the list spreads and settles.
            translationY = (if (mine) 70f else 18f) * (1 - p) + stretch * (index.coerceAtMost(14) / 5f)
            translationX += drag.value * 0.6f
            alpha = p
        },
        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start, verticalAlignment = Alignment.Bottom) {
        if (!mine && isGroup) {
            if (last) Avatar(m.senderUserID, engine.name(m.senderUserID), 28.dp, mediaID = engine.user(m.senderUserID)?.avatarMediaID?.toString())
            else Spacer(Modifier.size(28.dp))
            Spacer(Modifier.size(6.dp))
        }
        Column(horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
            if (isGroup && !mine && first) Text(engine.name(m.senderUserID), Modifier.padding(start = 12.dp, bottom = 2.dp),
                color = identityColor(m.senderUserID), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Box {
                Bubble(m, mine, last, Modifier.combinedClickable(onClick = {}, onLongClick = { menu = true },
                    onDoubleClick = { scope.launch { engine.react(AsgardApp.prefs.doubleTapReaction, m) } }))
                MessageMenu(m, mine, menu, { menu = false }, onReply, onEdit)
            }
            if (m.reactions.isNotEmpty()) Row(Modifier.padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                m.reactions.forEach { r ->
                    val me = engine.myID in r.userIDs
                    Text("${r.emoji} ${r.userIDs.size}", Modifier.clip(RoundedCornerShape(50))
                        .background(if (me) MaterialTheme.colorScheme.primary.copy(alpha = 0.35f) else Color.White.copy(alpha = 0.12f))
                        .clickable { scope.launch { engine.react(r.emoji, m) } }.padding(horizontal = 7.dp, vertical = 2.dp), fontSize = 13.sp)
                }
            }
        }
    }
}

@Composable
private fun Bubble(m: MessageEntity, mine: Boolean, tail: Boolean, modifier: Modifier) {
    val engine = AsgardApp.engine
    val appearance = LocalAppearance.current
    val big = 18.dp
    val small = if (tail && appearance.bubbles == BubbleStyle.Tailed) 5.dp else big
    val shape = if (mine) RoundedCornerShape(big, big, small, big) else RoundedCornerShape(big, big, big, small)
    val content = m.content
    Column(modifier.widthIn(max = 300.dp).clip(shape)
        .then(if (mine) Modifier.background(appearance.accent.fill) else Modifier.glass(shape, strong = true))
        .padding(horizontal = 12.dp, vertical = 8.dp)) {
        val fg = if (mine) Color.White else MaterialTheme.colorScheme.onSurface
        content?.replyTo?.let { rid ->
            var target by remember { mutableStateOf<MessageEntity?>(null) }
            LaunchedEffect(rid) { target = engine.dao.message(rid.toString().lowercase()) }
            target?.let { t ->
                Row(Modifier.padding(bottom = 4.dp).clip(RoundedCornerShape(8.dp)).background(Color.Black.copy(alpha = 0.15f)).padding(6.dp)) {
                    Box(Modifier.size(3.dp, 30.dp).background(if (mine) Color.White else identityColor(t.senderUserID)))
                    Column(Modifier.padding(start = 6.dp)) {
                        Text(engine.name(t.senderUserID), color = fg, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        Text(t.content?.let { ChatEngine.preview(it) } ?: "", color = fg.copy(alpha = 0.8f), fontSize = 12.sp, maxLines = 1)
                    }
                }
            }
        }
        when {
            m.wasDeleted -> Text("Message deleted", color = fg.copy(alpha = 0.7f), fontSize = 15.sp)
            m.decryptFailed -> Text("🔒 Waiting for this message. Restore history or ask the sender to resend.", color = fg.copy(alpha = 0.8f), fontSize = 14.sp)
            content != null -> ContentBody(content, mine, fg, m)
        }
        Row(Modifier.align(Alignment.End).padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            if (m.editedAt != null) Text("edited ", color = fg.copy(alpha = 0.6f), fontSize = 11.sp)
            Text(Instant.ofEpochMilli(m.sentAt).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)),
                color = fg.copy(alpha = 0.6f), fontSize = 11.sp)
            if (mine) {
                val reads by engine.readMarks.collectAsState()
                val read = reads[m.conversationID]?.any { (u, s) -> u != engine.myID && s >= m.seq && m.seq > 0 } == true
                val icon = when { m.statusEnum == MessageStatus.sending -> Icons.Filled.Schedule; m.statusEnum == MessageStatus.failed -> Icons.Filled.ErrorOutline; read -> Icons.Filled.DoneAll; else -> Icons.Filled.Done }
                Icon(icon, null, Modifier.padding(start = 3.dp).size(13.dp), tint = if (m.statusEnum == MessageStatus.failed) Color(0xFFFF6B6B) else fg.copy(alpha = 0.7f))
            }
        }
    }
}

@Composable
private fun ContentBody(c: MessageContent, mine: Boolean, fg: Color, m: MessageEntity) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    c.attachments?.forEach { a ->
        if (a.mime.startsWith("image/")) {
            var img by remember(a.mediaID) { mutableStateOf<ImageBitmap?>(a.thumbnail?.let { BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() }) }
            var failed by remember(a.mediaID) { mutableStateOf(false) }
            val context = LocalContext.current
            var allowed by remember(a.mediaID) { mutableStateOf(mine || autoDownloadAllowed(context)) }
            LaunchedEffect(a.mediaID, allowed) {
                if (!allowed) return@LaunchedEffect
                val full = runCatching { val d = engine.attachmentData(a); withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(d, 0, d.size)?.asImageBitmap() } }.getOrNull()
                if (full != null) img = full else failed = img == null
            }
            var viewing by remember { mutableStateOf(false) }
            val ratio = ((a.width ?: img?.width ?: 4).toFloat() / (a.height ?: img?.height ?: 3).toFloat()).coerceIn(0.5f, 2.2f)
            val frame = Modifier.padding(bottom = 4.dp).widthIn(max = 276.dp).fillMaxWidth().androidxAspect(ratio).clip(RoundedCornerShape(12.dp))
            val shown = img
            if (shown != null) {
                Image(shown, "Photo", frame.clickable { viewing = true }, contentScale = ContentScale.Crop, filterQuality = androidx.compose.ui.graphics.FilterQuality.High)
                if (viewing) PhotoViewer(shown, a) { viewing = false }
            } else Box(frame.background(Color.White.copy(alpha = 0.1f)).clickable(enabled = !allowed) { allowed = true }, contentAlignment = Alignment.Center) {
                if (!allowed) Text("Tap to download · " + android.text.format.Formatter.formatShortFileSize(context, a.size.toLong()), color = fg, fontSize = 13.sp)
                else if (failed) Text("Photo couldn't be shown", color = fg.copy(alpha = 0.7f), fontSize = 13.sp)
                else androidx.compose.material3.CircularProgressIndicator(Modifier.size(24.dp), color = fg, strokeWidth = 2.dp)
            }
        } else if (a.mime.startsWith("audio/")) {
            VoiceNote(a, fg)
        } else {
            val ctx = LocalContext.current
            Row(Modifier.padding(bottom = 4.dp).clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(alpha = 0.15f))
                .combinedClickable(onClick = { shareAttachment(ctx, a, view = true) }, onLongClick = { shareAttachment(ctx, a) }).padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.AutoMirrored.Filled.InsertDriveFile, null, tint = fg)
                Column(Modifier.padding(start = 8.dp)) {
                    Text(a.name ?: if (a.mime.startsWith("audio/")) "Voice message" else "File", color = fg, maxLines = 1)
                    Text(android.text.format.Formatter.formatShortFileSize(LocalContext.current, a.size.toLong()), color = fg.copy(alpha = 0.7f), fontSize = 12.sp)
                }
            }
        }
    }
    when (c.type) {
        "poll" -> c.poll?.let { poll ->
            val votes = m.votes
            val myVotes = votes[engine.myID] ?: emptyList()
            Text("📊 ${poll.question}", color = fg, fontWeight = FontWeight.SemiBold)
            poll.options.forEach { o ->
                val n = votes.values.count { o.id in it }
                val pct = if (votes.isEmpty()) 0f else n.toFloat() / votes.size
                Column(Modifier.padding(vertical = 4.dp).clickable {
                    val next = if (o.id in myVotes) myVotes - o.id else if (poll.multiple) myVotes + o.id else listOf(o.id)
                    scope.launch { engine.vote(next, m) }
                }) {
                    Row { Text((if (o.id in myVotes) "◉ " else "○ ") + o.text, color = fg, modifier = Modifier.weight(1f)); Text("${(pct * 100).toInt()}%", color = fg, fontSize = 12.sp) }
                    Box(Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.2f))) {
                        Box(Modifier.fillMaxWidth(pct).height(5.dp).background(Color.White.copy(alpha = 0.85f)))
                    }
                }
            }
            Text("${votes.size} votes", color = fg.copy(alpha = 0.7f), fontSize = 12.sp)
        }
        "event" -> c.event?.let { e ->
            Text("📅 ${e.title}", color = fg, fontWeight = FontWeight.SemiBold)
            Text(e.startsAt.atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)), color = fg, fontSize = 13.sp)
        }
        "location", "live_location" -> Text("📍 ${c.location?.name ?: "Location"}", color = fg)
        else -> if (!c.text.isNullOrEmpty()) Text(c.text, color = fg, fontSize = 16.sp) else if (c.attachments.isNullOrEmpty()) Text(ChatEngine.preview(c), color = fg, fontSize = 16.sp)
    }
}

@Composable
private fun MessageMenu(m: MessageEntity, mine: Boolean, open: Boolean, dismiss: () -> Unit, onReply: (MessageEntity) -> Unit, onEdit: (MessageEntity) -> Unit) {
    val engine = AsgardApp.engine
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    DropdownMenu(open, dismiss) {
        Row(Modifier.padding(horizontal = 8.dp)) {
            listOf("❤️", "👍", "😂", "😮", "😢", "🔥").forEach { e ->
                Text(e, Modifier.clip(CircleShape).clickable { dismiss(); scope.launch { engine.react(e, m) } }.padding(6.dp), fontSize = 24.sp)
            }
        }
        DropdownMenuItem({ Text("Reply") }, { dismiss(); onReply(m) }, leadingIcon = { Icon(Icons.AutoMirrored.Filled.Reply, null) })
        m.content?.text?.let { t -> DropdownMenuItem({ Text("Copy") }, { dismiss(); clipboard.setText(AnnotatedString(t)) }) }
        if (mine && m.content?.type == "text") DropdownMenuItem({ Text("Edit") }, { dismiss(); onEdit(m) })
        DropdownMenuItem({ Text(if (m.isPinned) "Unpin" else "Pin") }, { dismiss(); scope.launch { engine.pin(m, !m.isPinned) } })
        DropdownMenuItem({ Text(if (m.isStarred) "Unstar" else "Star") }, { dismiss(); scope.launch { engine.star(m) } })
        if (m.statusEnum == MessageStatus.failed) DropdownMenuItem({ Text("Retry sending") }, { dismiss(); scope.launch { engine.retry(m) } })
        if (mine) DropdownMenuItem({ Text("Delete for everyone", color = MaterialTheme.colorScheme.error) }, { dismiss(); scope.launch { engine.deleteForEveryone(m) } })
        DropdownMenuItem({ Text("Delete on this phone", color = MaterialTheme.colorScheme.error) }, { dismiss(); scope.launch { engine.deleteForMe(m) } })
    }
}

@Composable
private fun Composer(conversationID: String, replyTo: MessageEntity?, editing: MessageEntity?, draft: String, clear: () -> Unit) {
    val engine = AsgardApp.engine
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var text by remember(conversationID) { mutableStateOf(draft) }
    LaunchedEffect(editing) { editing?.content?.text?.let { text = it } }
    LaunchedEffect(text) { delay(400); engine.saveDraft(conversationID, if (editing == null) text else "") }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            val files = withContext(Dispatchers.IO) { uris.mapNotNull { readFile(context, it) } }
            engine.sendFiles(files, text.ifBlank { null }, conversationID, replyTo = replyTo?.id)
            text = ""; clear()
        }
    }
    var recorder by remember { mutableStateOf<VoiceRecorder?>(null) }
    var attachMenu by remember { mutableStateOf(false) }
    var poll by remember { mutableStateOf(false) }
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) recorder = VoiceRecorder(context).also { runCatching { it.start() } }
    }
    fun startRecording() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
            recorder = VoiceRecorder(context).also { runCatching { it.start() } }
        else askMic.launch(Manifest.permission.RECORD_AUDIO)
    }
    fun stopRecording(send: Boolean) {
        val note = recorder?.stop(send)
        recorder = null
        if (note != null) scope.launch { engine.sendFiles(listOf(note), null, conversationID, type = "voice", replyTo = replyTo?.id); clear() }
    }
    if (poll) PollComposer({ poll = false }) { q, options, multiple ->
        poll = false
        scope.launch {
            engine.send(MessageContent(type = "poll", poll = MessageContent.Poll(q, options.mapIndexed { i, t -> MessageContent.Poll.Option(('a' + i).toString(), t) }, multiple)), conversationID)
        }
    }
    fun send() {
        val t = text.trim()
        if (t.isEmpty()) return
        val e = editing; val r = replyTo
        scope.launch { if (e != null) engine.edit(e, t) else engine.send(MessageContent.text(t), conversationID, r?.id) }
        text = ""
        clear()
    }
    Column(Modifier.navigationBarsPadding().padding(horizontal = 10.dp, vertical = 6.dp)) {
        (editing ?: replyTo)?.let { r ->
            Row(Modifier.fillMaxWidth().padding(bottom = 6.dp).glass(RoundedCornerShape(16.dp)).padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(if (editing != null) "Editing" else "Replying to ${engine.name(r.senderUserID)}", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
                    Text(r.content?.let { ChatEngine.preview(it) } ?: "", fontSize = 13.sp, maxLines = 1, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton({ if (editing != null) text = ""; clear() }) { Icon(Icons.Filled.Close, "Cancel") }
            }
        }
        val rec = recorder
        if (rec != null) {
            Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(26.dp)).padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton({ stopRecording(false) }) { Icon(Icons.Filled.Delete, "Cancel recording", tint = Color(0xFFFF6B6B)) }
                Box(Modifier.size(10.dp).clip(CircleShape).background(Color(0xFFFF453A).copy(alpha = 0.5f + rec.level / 2)))
                val s = rec.elapsedMs / 1000
                Text("  Recording  %d:%02d".format(s / 60, s % 60), Modifier.weight(1f), fontSize = 15.sp)
                IconButton({ stopRecording(true) }, Modifier.clip(CircleShape).background(LocalAppearance.current.accent.fill)) { Icon(Icons.Filled.ArrowUpward, "Send voice message", tint = Color.White) }
            }
            return@Column
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Box {
                IconButton({ attachMenu = true }, Modifier.glass(CircleShape)) { Icon(Icons.Filled.Add, "Attach", tint = MaterialTheme.colorScheme.primary) }
                DropdownMenu(attachMenu, { attachMenu = false }) {
                    DropdownMenuItem({ Text("Photos & files") }, { attachMenu = false; pick.launch("*/*") }, leadingIcon = { Icon(Icons.Filled.Photo, null) })
                    DropdownMenuItem({ Text("Poll") }, { attachMenu = false; poll = true }, leadingIcon = { Icon(Icons.Filled.Poll, null) })
                }
            }
            val enterSends = AsgardApp.prefs.enterToSend
            TextField(text, { text = it; if (it.isNotEmpty()) engine.setTyping(conversationID) }, Modifier.weight(1f).padding(horizontal = 8.dp).glass(RoundedCornerShape(22.dp)),
                placeholder = { Text("Message") }, maxLines = 6,
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                    capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.Sentences,
                    imeAction = if (enterSends) androidx.compose.ui.text.input.ImeAction.Send else androidx.compose.ui.text.input.ImeAction.Default),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSend = { send() }),
                colors = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, cursorColor = MaterialTheme.colorScheme.primary))
            if (text.isBlank() && editing == null) IconButton(::startRecording, Modifier.glass(CircleShape)) { Icon(Icons.Filled.Mic, "Record voice message", tint = MaterialTheme.colorScheme.primary) }
            else IconButton(::send, Modifier.clip(CircleShape).background(LocalAppearance.current.accent.fill)) { Icon(Icons.Filled.ArrowUpward, "Send", tint = Color.White) }
        }
    }
}

private fun readFile(context: android.content.Context, uri: Uri): OutgoingFile? {
    val cr = context.contentResolver
    val mime = cr.getType(uri) ?: "application/octet-stream"
    val name = cr.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    val data = cr.openInputStream(uri)?.use { it.readBytes() } ?: return null
    if (mime.startsWith("image/") && mime != "image/gif") {
        val bmp = BitmapFactory.decodeByteArray(data, 0, data.size) ?: return OutgoingFile(data, mime, name)
        val scale = minOf(1f, 2560f / maxOf(bmp.width, bmp.height))
        val scaled = if (scale < 1f) android.graphics.Bitmap.createScaledBitmap(bmp, (bmp.width * scale).toInt(), (bmp.height * scale).toInt(), true) else bmp
        val jpeg = ByteArrayOutputStream().also { scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
        val ts = 64f / maxOf(bmp.width, bmp.height)
        val thumb = ByteArrayOutputStream().also {
            android.graphics.Bitmap.createScaledBitmap(bmp, maxOf(1, (bmp.width * ts).toInt()), maxOf(1, (bmp.height * ts).toInt()), true).compress(android.graphics.Bitmap.CompressFormat.JPEG, 60, it)
        }.toByteArray()
        return OutgoingFile(jpeg, "image/jpeg", name ?: "Photo.jpg", scaled.width, scaled.height, thumbnail = thumb)
    }
    return OutgoingFile(data, mime, name)
}

@Composable
private fun PollComposer(dismiss: () -> Unit, create: (String, List<String>, Boolean) -> Unit) {
    var question by remember { mutableStateOf("") }
    val options = remember { androidx.compose.runtime.mutableStateListOf("", "") }
    var multiple by remember { mutableStateOf(false) }
    AlertDialog(dismiss, title = { Text("New poll") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(question, { question = it }, Modifier.fillMaxWidth(), label = { Text("Question") })
            options.forEachIndexed { i, o -> OutlinedTextField(o, { options[i] = it; if (i == options.lastIndex && it.isNotBlank() && options.size < 10) options += "" },
                Modifier.fillMaxWidth(), label = { Text("Option ${i + 1}") }, singleLine = true) }
            Row(verticalAlignment = Alignment.CenterVertically) { androidx.compose.material3.Checkbox(multiple, { multiple = it }); Text("Allow several answers") }
        }
    }, confirmButton = {
        val opts = options.filter { it.isNotBlank() }
        TextButton({ create(question.trim(), opts.map { it.trim() }, multiple) }, enabled = question.isNotBlank() && opts.size >= 2) { Text("Send") }
    }, dismissButton = { TextButton(dismiss) { Text("Cancel") } })
}

private fun Modifier.androidxAspect(ratio: Float) = this.aspectRatio(ratio)

/** The in-app "Message animations" setting decides; ignore the system animator scale (battery saver zeroes it). */
private object FullMotion : androidx.compose.ui.MotionDurationScale { override val scaleFactor = 1f }

/** Bubbles fade out softly where they slide under the header and composer. */
private fun Modifier.softEdges() = this
    .graphicsLayer(compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen)
    .drawWithContent {
        drawContent()
        drawRect(Brush.verticalGradient(0f to Color.Transparent, 0.05f to Color.Black, 0.95f to Color.Black, 1f to Color.Transparent),
            blendMode = androidx.compose.ui.graphics.BlendMode.DstIn)
    }

/** Settings › Chats › Auto-download media, for Wi-Fi and mobile data. */
private fun autoDownloadAllowed(context: android.content.Context): Boolean {
    val cm = context.getSystemService(android.net.ConnectivityManager::class.java)
    val metered = cm?.isActiveNetworkMetered ?: false
    return if (metered) AsgardApp.prefs.autoDownloadCellular else AsgardApp.prefs.autoDownloadWifi
}
