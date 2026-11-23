package com.mac2tv.receiver.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme

object Mac2TvColors {
    val Blue = Color(0xFF4F7BFF)
    val Violet = Color(0xFF8B5CF6)
    val Background = Color(0xFF0A0E1A)
    val BackgroundAlt = Color(0xFF15102B)
    val Surface = Color(0xFF161C2E)
    val SurfaceBorder = Color(0x1FFFFFFF)
    val OnSurface = Color(0xFFEEF1FA)
    val Muted = Color(0xFF9AA3BA)
    val Success = Color(0xFF34D399)
    val Warning = Color(0xFFFBBF24)
    val Error = Color(0xFFF87171)
    val Scrim = Color(0xCC0A0E1A)

    val BrandGradient = Brush.linearGradient(listOf(Blue, Violet))
    val BackgroundGradient = Brush.radialGradient(
        colors = listOf(BackgroundAlt, Background),
        radius = 1800f,
    )
}

private val colorScheme = darkColorScheme(
    primary = Mac2TvColors.Blue,
    onPrimary = Color.White,
    secondary = Mac2TvColors.Violet,
    background = Mac2TvColors.Background,
    onBackground = Mac2TvColors.OnSurface,
    surface = Mac2TvColors.Surface,
    onSurface = Mac2TvColors.OnSurface,
    onSurfaceVariant = Mac2TvColors.Muted,
    error = Mac2TvColors.Error,
)

@Composable
fun Mac2TvTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colorScheme, content = content)
}
