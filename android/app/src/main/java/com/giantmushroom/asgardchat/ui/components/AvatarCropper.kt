package com.giantmushroom.asgardchat.ui.components

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min

/** Decodes a picked photo upright (ImageDecoder applies EXIF rotation), capped at [maxSide]. */
fun decodePhoto(context: Context, uri: Uri, maxSide: Int = 2048): Bitmap? = runCatching {
    ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
        val s = info.size
        val k = min(1f, maxSide.toFloat() / max(s.width, s.height))
        decoder.setTargetSize((s.width * k).toInt().coerceAtLeast(1), (s.height * k).toInt().coerceAtLeast(1))
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
    }
}.getOrNull()

/** Full-screen drag-and-pinch framing inside a circle; returns a square JPEG of [side] pixels. */
@Composable
fun AvatarCropper(bitmap: Bitmap, side: Int = 640, onCancel: () -> Unit, onDone: (ByteArray) -> Unit) {
    Dialog(onDismissRequest = onCancel, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
            val density = LocalDensity.current
            val circlePx = with(density) { (if (maxWidth < maxHeight) maxWidth else maxHeight).toPx() - 48.dp.toPx() }
            // At zoom 1 the photo just covers the circle.
            val fill = circlePx / min(bitmap.width, bitmap.height)
            val baseW = bitmap.width * fill
            val baseH = bitmap.height * fill
            var zoom by remember { mutableFloatStateOf(1f) }
            var offset by remember { mutableStateOf(Offset.Zero) }
            fun clamp(o: Offset, z: Float): Offset {
                val mx = max(0f, (baseW * z - circlePx) / 2)
                val my = max(0f, (baseH * z - circlePx) / 2)
                return Offset(o.x.coerceIn(-mx, mx), o.y.coerceIn(-my, my))
            }
            val image = remember(bitmap) { bitmap.asImageBitmap() }
            Box(
                Modifier.fillMaxSize().pointerInput(Unit) {
                    detectTransformGestures { _, pan, gestureZoom, _ ->
                        zoom = (zoom * gestureZoom).coerceIn(1f, 6f)
                        offset = clamp(offset + pan, zoom)
                    }
                },
                contentAlignment = Alignment.Center,
            ) {
                Image(
                    image, null, contentScale = ContentScale.FillBounds,
                    modifier = Modifier
                        .requiredSize(with(density) { (baseW * zoom).toDp() }, with(density) { (baseH * zoom).toDp() })
                        .graphicsLayer { translationX = offset.x; translationY = offset.y },
                )
                Canvas(Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }) {
                    drawRect(Color.Black.copy(alpha = 0.55f))
                    drawCircle(Color.Transparent, circlePx / 2, blendMode = BlendMode.Clear)
                    drawCircle(Color.White.copy(alpha = 0.8f), circlePx / 2, style = Stroke(1.dp.toPx()))
                }
            }
            Row(Modifier.fillMaxWidth().systemBarsPadding().padding(8.dp), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.SpaceBetween) {
                TextButton(onCancel) { Text("Cancel", color = Color.White) }
                Text("Move and scale", color = Color.White, modifier = Modifier.align(Alignment.CenterVertically))
                TextButton({ onDone(render(bitmap, side, fill * zoom, offset, circlePx)) }) { Text("Choose", color = Color.White) }
            }
        }
    }
}

private fun render(bitmap: Bitmap, side: Int, scale: Float, offset: Offset, circlePx: Float): ByteArray {
    // Circle centre in bitmap pixels, and the circle's width in bitmap pixels.
    val srcSide = circlePx / scale
    val cx = bitmap.width / 2f - offset.x / scale
    val cy = bitmap.height / 2f - offset.y / scale
    val left = (cx - srcSide / 2).toInt().coerceIn(0, bitmap.width - 1)
    val top = (cy - srcSide / 2).toInt().coerceIn(0, bitmap.height - 1)
    val size = srcSide.toInt().coerceAtMost(min(bitmap.width - left, bitmap.height - top)).coerceAtLeast(1)
    val square = Bitmap.createBitmap(bitmap, left, top, size, size)
    val scaled = Bitmap.createScaledBitmap(square, side, side, true)
    return ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
}
