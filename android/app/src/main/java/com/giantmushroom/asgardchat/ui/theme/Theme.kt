package com.giantmushroom.asgardchat.ui.theme

import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import java.util.UUID

/** Asgard's visual language: Bifröst aurora on a night sky (same palette as iOS). */
object Brand {
    val night = Color(0xFF080B1F)
    val navy = Color(0xFF141838)
    val violet = Color(0xFF8B5CF6)
    val blue = Color(0xFF5C8CF0)
    val teal = Color(0xFF2DD4BF)
    val gold = Color(0xFFFBBF24)
    val aurora = Brush.linearGradient(listOf(violet, blue, teal))
    val bifrost = Brush.horizontalGradient(listOf(violet, teal, gold))
}

enum class Accent(val title: String, val color: Color) {
    Aurora("Aurora", Brand.violet), Violet("Violet", Brand.violet), Teal("Teal", Brand.teal), Gold("Gold", Brand.gold),
    Rose("Rose", Color(0xFFF472B6)), Ember("Ember", Color(0xFFF97316)), Frost("Frost", Color(0xFF60A5FA)), Moss("Moss", Color(0xFF34D399));

    val fill: Brush get() = if (this == Aurora) Brand.aurora else Brush.linearGradient(listOf(color, lerp(color, Color.Black, 0.18f)))
}

enum class ThemeChoice { Dark, Light, System }
enum class Wallpaper(val title: String) { Aurora("Aurora"), Stars("Stars"), Dusk("Dusk"), Fjord("Fjord"), Plain("Plain") }
enum class BubbleStyle { Rounded, Tailed, Minimal }

/** Appearance preferences, persisted per device. */
class Appearance(context: Context) {
    private val prefs = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)
    var theme by mutableStateOf(ThemeChoice.valueOf(prefs.getString("theme", "Dark")!!))
        private set
    var accent by mutableStateOf(Accent.valueOf(prefs.getString("accent", "Aurora")!!))
        private set
    var bubbles by mutableStateOf(BubbleStyle.valueOf(prefs.getString("bubbles", "Tailed")!!))
        private set
    var animatedBackgrounds by mutableStateOf(prefs.getBoolean("animatedBackgrounds", true))
        private set
    var messageAnimations by mutableStateOf(prefs.getBoolean("messageAnimations", true))
        private set
    var wallpaper by mutableStateOf(runCatching { Wallpaper.valueOf(prefs.getString("wallpaper", "Aurora")!!) }.getOrDefault(Wallpaper.Aurora))
        private set
    var textScale by mutableStateOf(prefs.getFloat("textScale", 1f))
        private set

    fun chooseWallpaper(w: Wallpaper) { wallpaper = w; prefs.edit().putString("wallpaper", w.name).apply() }
    fun chooseTextScale(v: Float) { textScale = v; prefs.edit().putFloat("textScale", v).apply() }

    fun update(theme: ThemeChoice = this.theme, accent: Accent = this.accent, bubbles: BubbleStyle = this.bubbles,
               animatedBackgrounds: Boolean = this.animatedBackgrounds, messageAnimations: Boolean = this.messageAnimations) {
        this.theme = theme; this.accent = accent; this.bubbles = bubbles
        this.animatedBackgrounds = animatedBackgrounds; this.messageAnimations = messageAnimations
        prefs.edit().putString("theme", theme.name).putString("accent", accent.name).putString("bubbles", bubbles.name)
            .putBoolean("animatedBackgrounds", animatedBackgrounds).putBoolean("messageAnimations", messageAnimations).apply()
    }
}

val LocalAppearance = compositionLocalOf<Appearance> { error("no appearance") }

/** Stable pleasant colour for an id (avatars, sender names), matching iOS. */
fun identityColor(id: String?): Color {
    val palette = listOf(Brand.violet, Brand.teal, Brand.gold, Color(0xFFFF2D92), Color(0xFFFF9500), Color(0xFF60A5FA),
        Color(0xFF00C7BE), Color(0xFF5856D6), Color(0xFFFF3B30), Color(0xFF32ADE6))
    val u = runCatching { UUID.fromString(id) }.getOrNull() ?: return Color.Gray
    val b = ByteArray(16).also { java.nio.ByteBuffer.wrap(it).putLong(u.mostSignificantBits).putLong(u.leastSignificantBits) }
    val h = (b[0].toInt() xor b[5].toInt() xor b[10].toInt() xor b[15].toInt()) and 0xff
    return palette[h % palette.size]
}

@Composable
fun AsgardTheme(appearance: Appearance, content: @Composable () -> Unit) {
    val dark = when (appearance.theme) { ThemeChoice.Dark -> true; ThemeChoice.Light -> false; ThemeChoice.System -> isSystemInDarkTheme() }
    val accent = appearance.accent.color
    val scheme = if (dark) darkColorScheme(
        primary = accent, onPrimary = Color.White, secondary = Brand.teal, tertiary = Brand.gold,
        background = Brand.night, surface = Brand.night, surfaceVariant = Color(0x1FFFFFFF), onSurface = Color.White,
        onSurfaceVariant = Color(0xB3FFFFFF), outline = Color(0x33FFFFFF), surfaceContainer = Color(0xFF12152E),
        surfaceContainerHigh = Color(0xFF1A1E3D), surfaceContainerHighest = Color(0xFF222748),
    ) else lightColorScheme(
        primary = accent, onPrimary = Color.White, secondary = Brand.teal, tertiary = Brand.gold,
        background = Color(0xFFF5F3FF), surface = Color(0xFFF5F3FF), surfaceVariant = Color(0x14000000),
        onSurfaceVariant = Color(0x99000000), outline = Color(0x22000000),
    )
    MaterialTheme(colorScheme = scheme) {
        // Text outside a Surface takes LocalContentColor, which defaults to black.
        val density = androidx.compose.ui.platform.LocalDensity.current
        androidx.compose.runtime.CompositionLocalProvider(
            androidx.compose.material3.LocalContentColor provides scheme.onSurface,
            // Settings › Appearance › Text size, on top of the system font size.
            androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(density.density, density.fontScale * appearance.textScale),
            content = content,
        )
    }
}
