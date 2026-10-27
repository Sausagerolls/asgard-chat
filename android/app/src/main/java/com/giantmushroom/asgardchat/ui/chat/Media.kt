package com.giantmushroom.asgardchat.ui.chat

import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.engine.OutgoingFile
import com.giantmushroom.asgardchat.net.MessageContent
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.max

/** Records AAC voice notes (same format as iPhone: audio/mp4, 24 kHz mono) and samples a 64-point waveform. */
class VoiceRecorder(private val context: Context) {
    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private val levels = mutableListOf<Int>()
    private var started = 0L
    private var sampler: Job? = null
    var level by mutableFloatStateOf(0f); private set
    var elapsedMs by mutableStateOf(0L); private set

    fun start() {
        val f = File(context.cacheDir, "voice-${System.currentTimeMillis()}.m4a")
        file = f
        levels.clear()
        recorder = (if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()).apply {
            setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioSamplingRate(24_000)
            setAudioChannels(1)
            setAudioEncodingBitRate(32_000)
            setOutputFile(f.absolutePath)
            prepare()
            start()
        }
        started = System.currentTimeMillis()
        sampler = AsgardApp.engine.scope.launch {
            while (recorder != null) {
                val amp = runCatching { recorder?.maxAmplitude ?: 0 }.getOrDefault(0)
                levels += amp
                level = (amp / 20_000f).coerceIn(0f, 1f)
                elapsedMs = System.currentTimeMillis() - started
                delay(50)
            }
        }
    }

    /** Stops and returns the note, or null if cancelled or too short. */
    fun stop(keep: Boolean): OutgoingFile? {
        sampler?.cancel()
        val duration = System.currentTimeMillis() - started
        runCatching { recorder?.stop() }
        recorder?.release()
        recorder = null
        val f = file ?: return null
        if (!keep || duration < 600) { f.delete(); return null }
        val data = f.readBytes().also { f.delete() }
        return OutgoingFile(data, "audio/mp4", "Voice message.m4a", durationMS = duration.toInt(), waveform = downsample(levels, 64))
    }

    private fun downsample(values: List<Int>, n: Int): ByteArray {
        if (values.isEmpty()) return ByteArray(n) { 40 }
        val peak = max(1, values.max())
        return ByteArray(n) { i ->
            val from = i * values.size / n
            val to = max(from + 1, (i + 1) * values.size / n)
            val v = values.subList(from, minOf(to, values.size)).maxOrNull() ?: 0
            (v * 255 / peak).coerceIn(12, 255).toByte()
        }
    }
}

/** Plays decrypted voice notes; one at a time across the app. */
object VoicePlayer {
    private var player: MediaPlayer? = null
    var playing by mutableStateOf<String?>(null); private set
    var progress by mutableFloatStateOf(0f); private set
    private var ticker: Job? = null

    fun toggle(context: Context, a: MessageContent.Attachment) {
        val id = a.mediaID.toString()
        if (playing == id) { stop(); return }
        stop()
        AsgardApp.engine.scope.launch {
            val data = runCatching { AsgardApp.engine.attachmentData(a) }.getOrNull() ?: return@launch
            val f = File(context.cacheDir, "play-$id.m4a").apply { writeBytes(data) }
            player = MediaPlayer().apply {
                setDataSource(f.absolutePath)
                setOnCompletionListener { stop() }
                prepare()
                start()
            }
            playing = id
            ticker = launch { while (true) { player?.let { if (it.duration > 0) progress = it.currentPosition / it.duration.toFloat() }; delay(100) } }
        }
    }

    fun stop() {
        ticker?.cancel()
        runCatching { player?.stop() }
        player?.release()
        player = null
        playing = null
        progress = 0f
    }
}

@Composable
fun VoiceNote(a: MessageContent.Attachment, fg: Color) {
    val context = LocalContext.current
    val id = a.mediaID.toString()
    val isPlaying = VoicePlayer.playing == id
    val levels = remember(a.waveform) { (a.waveform ?: ByteArray(40) { 40 }).map { (it.toInt() and 0xff) / 255f } }
    Row(Modifier.padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(38.dp).background(fg.copy(alpha = 0.2f), CircleShape).clickable { VoicePlayer.toggle(context, a) }, contentAlignment = Alignment.Center) {
            Icon(if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (isPlaying) "Pause" else "Play", tint = fg)
        }
        val progress = if (isPlaying) VoicePlayer.progress else 0f
        Canvas(Modifier.padding(horizontal = 10.dp).width(150.dp).height(28.dp)) {
            val n = levels.size
            val w = size.width / n
            levels.forEachIndexed { i, v ->
                val h = max(3f, v * size.height)
                drawRoundRect(if (i / n.toFloat() < progress) fg else fg.copy(alpha = 0.45f), Offset(i * w + w * 0.2f, (size.height - h) / 2),
                    Size(w * 0.6f, h), CornerRadius(w))
            }
        }
        val s = (a.durationMS ?: 0) / 1000
        Text("%d:%02d".format(s / 60, s % 60), color = fg.copy(alpha = 0.8f), fontSize = 12.sp)
    }
}

/** Full-screen photo with pinch to zoom. */
@Composable
fun PhotoViewer(image: ImageBitmap, attachment: MessageContent.Attachment, dismiss: () -> Unit) {
    val context = LocalContext.current
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    Dialog(dismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            Image(image, null, Modifier.fillMaxSize().pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ -> scale = (scale * zoom).coerceIn(1f, 6f); offset = if (scale > 1f) offset + pan else Offset.Zero }
            }.graphicsLayer { scaleX = scale; scaleY = scale; translationX = offset.x; translationY = offset.y }, contentScale = ContentScale.Fit)
            Row(Modifier.statusBarsPadding().padding(8.dp)) {
                IconButton(dismiss) { Icon(Icons.Filled.Close, "Close", tint = Color.White) }
                IconButton({ shareAttachment(context, attachment) }) { Icon(Icons.Filled.Share, "Share", tint = Color.White) }
            }
        }
    }
}

/** Decrypts to a private cache file and hands it to another app (view, save to Files, share). */
fun shareAttachment(context: Context, a: MessageContent.Attachment, view: Boolean = false) {
    AsgardApp.engine.scope.launch {
        val data = runCatching { AsgardApp.engine.attachmentData(a) }.getOrNull() ?: return@launch
        val dir = File(context.cacheDir, "shared").apply { mkdirs() }
        val f = File(dir, a.name ?: "attachment").apply { writeBytes(data) }
        val uri = FileProvider.getUriForFile(context, context.packageName + ".files", f)
        val intent = if (view) Intent(Intent.ACTION_VIEW).setDataAndType(uri, a.mime)
        else Intent(Intent.ACTION_SEND).setType(a.mime).putExtra(Intent.EXTRA_STREAM, uri)
        context.startActivity(Intent.createChooser(intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
