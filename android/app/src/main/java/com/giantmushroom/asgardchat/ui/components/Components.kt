package com.giantmushroom.asgardchat.ui.components

import android.graphics.BitmapFactory
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.giantmushroom.asgardchat.AsgardApp
import com.giantmushroom.asgardchat.ui.theme.Brand
import com.giantmushroom.asgardchat.ui.theme.LocalAppearance
import com.giantmushroom.asgardchat.ui.theme.identityColor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.sin

/**
 * Drifting aurora: curtains of colour that move and breathe over a twinkling
 * night sky (same motion as the iPhone app). Follows Settings › Appearance ›
 * Animated backgrounds.
 */
@Composable
fun AuroraBackground(intensity: Float = 1f, modifier: Modifier = Modifier) {
    val dark = MaterialTheme.colorScheme.background.luminanceIsDark()
    val animated = LocalAppearance.current.animatedBackgrounds
    // Seconds since start, advanced about 30 times a second (like iOS) while animated.
    var t by remember { mutableStateOf(0f) }
    if (animated) LaunchedEffect(Unit) {
        val start = withFrameNanos { it }
        while (true) {
            withFrameNanos { now -> t = (now - start) / 1_000_000_000f }
            kotlinx.coroutines.delay(33)
        }
    }
    val base = MaterialTheme.colorScheme.background
    val night = if (dark) Brand.navy else Color(0xFFE9E5FF)
    Canvas(modifier.fillMaxSize()) {
        drawRect(base)
        val w = size.width; val h = size.height
        fun s(phase: Float, speed: Float) = sin(t * speed + phase)
        fun blob(c: Color, x: Float, y: Float, r: Float) = drawCircle(Brush.radialGradient(listOf(c, Color.Transparent), Offset(x, y), r), r, Offset(x, y))
        val pv = 0.75f + 0.25f * s(0f, 0.45f); val pt = 0.7f + 0.3f * s(2f, 0.37f); val pg = 0.6f + 0.4f * s(4f, 0.29f)
        blob(night.copy(alpha = 0.75f), w * (0.5f + 0.18f * s(2.1f, 0.41f)), h * (0.5f + 0.14f * s(0.7f, 0.36f)), w * 0.8f)
        blob(Brand.violet.copy(alpha = 0.6f * intensity * pv), w * (0.12f + 0.3f * s(0f, 0.33f)), h * (0.06f + 0.12f * s(1.3f, 0.27f)), w * 1.0f)
        blob(Brand.teal.copy(alpha = 0.42f * intensity * pt), w * (0.95f + 0.25f * s(2.6f, 0.3f)), h * (0.72f + 0.14f * s(1f, 0.33f)), w * 0.9f)
        blob(Brand.gold.copy(alpha = 0.22f * intensity * pg), w * (0.4f + 0.3f * s(3.4f, 0.29f)), h * 1.02f, w * 0.65f)
        if (dark) {
            var seed = 7L
            fun next(): Float { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) and 0x7fffffff).toFloat() / 0x7fffffff }
            repeat(80) {
                val x = next() * w; val y = next() * h * 0.7f; val r = 0.6f + next() * 1.8f
                val baseA = 0.15f + next() * 0.5f; val phase = next() * 6.28f; val speed = 0.6f + next() * 1.6f
                drawCircle(Color.White.copy(alpha = (baseA * (0.55f + 0.45f * sin(t * speed + phase))).coerceIn(0f, 1f)), r, Offset(x, y))
            }
        }
    }
}

private fun Color.luminanceIsDark() = (0.299f * red + 0.587f * green + 0.114f * blue) < 0.5f

/** Translucent "liquid glass" surface: tinted fill, hairline highlight. */
fun Modifier.glass(shape: Shape = RoundedCornerShape(22.dp), tint: Color = Color.Unspecified, strong: Boolean = false): Modifier = composedGlass(shape, tint, strong)

private fun Modifier.composedGlass(shape: Shape, tint: Color, strong: Boolean) = this
    .clip(shape)
    .background(if (tint != Color.Unspecified) tint.copy(alpha = 0.28f) else Color.White.copy(alpha = if (strong) 0.14f else 0.08f), shape)
    .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.10f), Color.Transparent)), shape)
    .border(0.6.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.35f), Color.White.copy(alpha = 0.06f))), shape)

/** Avatar images are not end-to-end encrypted; they're fetched with the session token and cached. */
object AvatarCache {
    private val cache = ConcurrentHashMap<String, ImageBitmap>()
    fun get(id: String) = cache[id]
    suspend fun load(id: String): ImageBitmap? {
        cache[id]?.let { return it }
        val api = AsgardApp.engine.api ?: return null
        val bytes = runCatching { api.download(UUID.fromString(id)) }.getOrNull() ?: return null
        val bmp = withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap() } ?: return null
        cache[id] = bmp
        return bmp
    }
}

@Composable
fun Avatar(id: String?, name: String, size: Dp = 44.dp, mediaID: String? = null, online: Boolean = false, kind: String? = null, modifier: Modifier = Modifier) {
    var image by remember(mediaID) { mutableStateOf(mediaID?.let { AvatarCache.get(it) }) }
    LaunchedEffect(mediaID) { if (mediaID != null && image == null) image = AvatarCache.load(mediaID) }
    val shape: Shape = if (kind == "community") RoundedCornerShape(size * 0.3f) else CircleShape
    Box(modifier.size(size)) {
        Box(Modifier.size(size).clip(shape), contentAlignment = Alignment.Center) {
            val img = image
            when {
                img != null -> Image(img, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                kind == "saved" -> { Box(Modifier.fillMaxSize().background(Brand.aurora)); Text("🔖", fontSize = (size.value * 0.4f).sp) }
                else -> {
                    val c = identityColor(id)
                    Box(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(lerp(c, Color.White, 0.15f), lerp(c, Color.Black, 0.25f)))))
                    Text(if (kind == "channel") "📣" else initials(name), color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (size.value * 0.38f).sp)
                }
            }
        }
        if (online) Box(Modifier.align(Alignment.BottomEnd).offset((-1).dp, (-1).dp).size(size * 0.26f).clip(CircleShape)
            .background(Brand.teal).border(size * 0.05f, MaterialTheme.colorScheme.background, CircleShape))
    }
}

private fun initials(name: String) = name.split(" ").filter { it.isNotEmpty() }.take(2).joinToString("") { it.first().uppercase() }.ifEmpty { "?" }

@Composable
fun Badge(count: Int, muted: Boolean = false) {
    Box(Modifier.clip(CircleShape).background(if (muted) Color.Gray else MaterialTheme.colorScheme.primary).padding(horizontal = 7.dp, vertical = 2.dp), contentAlignment = Alignment.Center) {
        Text("$count", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun GlassBox(modifier: Modifier = Modifier, shape: Shape = RoundedCornerShape(22.dp), content: @Composable BoxScope.() -> Unit) =
    Box(modifier.glass(shape), content = content)

/** Chat background chosen in Settings › Appearance (same set as iPhone). */
@Composable
fun ChatWallpaper(wallpaper: com.giantmushroom.asgardchat.ui.theme.Wallpaper, modifier: Modifier = Modifier) {
    val dark = MaterialTheme.colorScheme.background.luminanceIsDark()
    when (wallpaper) {
        com.giantmushroom.asgardchat.ui.theme.Wallpaper.Aurora -> AuroraBackground(0.7f, modifier)
        com.giantmushroom.asgardchat.ui.theme.Wallpaper.Stars -> AuroraBackground(0f, modifier)
        com.giantmushroom.asgardchat.ui.theme.Wallpaper.Dusk -> Box(modifier.fillMaxSize().background(Brush.verticalGradient(
            listOf(Color(0xFF331A59), Color(0xFF8C4059), Color(0xFFF28C4D)).map { if (dark) it else it.copy(alpha = 0.45f) })))
        com.giantmushroom.asgardchat.ui.theme.Wallpaper.Fjord -> Box(modifier.fillMaxSize().background(Brush.verticalGradient(
            listOf(Color(0xFF0D2640), Color(0xFF1A5973), Color(0xFF8CBFCC)).map { if (dark) it else it.copy(alpha = 0.45f) })))
        com.giantmushroom.asgardchat.ui.theme.Wallpaper.Plain -> Box(modifier.fillMaxSize().background(MaterialTheme.colorScheme.background))
    }
}
