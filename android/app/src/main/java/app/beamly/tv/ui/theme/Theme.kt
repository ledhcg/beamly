package app.beamly.tv.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme

object BeamlyColors {
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
        radius = 1800f
    )
}

private val colorScheme = darkColorScheme(
    primary = BeamlyColors.Blue,
    onPrimary = Color.White,
    secondary = BeamlyColors.Violet,
    background = BeamlyColors.Background,
    onBackground = BeamlyColors.OnSurface,
    surface = BeamlyColors.Surface,
    onSurface = BeamlyColors.OnSurface,
    onSurfaceVariant = BeamlyColors.Muted,
    error = BeamlyColors.Error
)

@Composable
fun BeamlyTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colorScheme, content = content)
}
