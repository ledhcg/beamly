package app.beamly.tv.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import app.beamly.tv.BuildConfig
import app.beamly.tv.Notice
import app.beamly.tv.R
import app.beamly.tv.ReceiverUiState
import app.beamly.tv.ui.theme.BeamlyColors
import kotlin.math.roundToInt

/** Safe area for TV overscan (about 5%). */
private val SafeArea = Modifier.padding(horizontal = 64.dp, vertical = 40.dp)

@Composable
fun FullScreenBackground(content: @Composable BoxScope.() -> Unit) {
    Box(Modifier.fillMaxSize().background(BeamlyColors.Background).background(BeamlyColors.BackgroundGradient)) {
        content()
    }
}

@Composable
fun StartingScreen() = FullScreenBackground {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        BreathingLogo()
        Spacer(Modifier.height(28.dp))
        Text(stringResource(R.string.status_starting), style = MaterialTheme.typography.titleLarge, color = BeamlyColors.Muted)
    }
}

@Composable
fun WaitingScreen(state: ReceiverUiState.Waiting, onNoticeShown: () -> Unit) = FullScreenBackground {
    if (state.notice != null) {
        LaunchedEffect(state.notice) {
            kotlinx.coroutines.delay(10_000)
            onNoticeShown()
        }
    }
    Row(SafeArea.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
        // Left column: branding and instructions
        Column(Modifier.weight(1.15f).padding(end = 48.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AppLogo(72.dp)
                Spacer(Modifier.width(20.dp))
                Column {
                    Text(
                        stringResource(R.string.app_name),
                        style = MaterialTheme.typography.displaySmall,
                        color = BeamlyColors.OnSurface,
                        fontWeight = FontWeight.Bold
                    )
                    Text(stringResource(R.string.tagline), style = MaterialTheme.typography.titleLarge, color = BeamlyColors.Muted)
                }
            }
            Spacer(Modifier.height(56.dp))
            NumberedStep(1, stringResource(R.string.step_1))
            Spacer(Modifier.height(24.dp))
            NumberedStep(2, stringResource(R.string.step_2, state.deviceName))
            Spacer(Modifier.height(24.dp))
            NumberedStep(3, stringResource(R.string.step_3))
            state.notice?.let { notice ->
                Spacer(Modifier.height(40.dp))
                NoticeBanner(noticeText(notice), BeamlyColors.Warning)
            }
        }

        // Right column: status and connection details
        Panel(Modifier.weight(0.85f)) {
            Column(Modifier.fillMaxWidth().padding(36.dp)) {
                StatusPill(stringResource(R.string.status_ready), BeamlyColors.Success, pulsing = true)
                Spacer(Modifier.height(32.dp))
                Text(stringResource(R.string.label_tv_name), style = MaterialTheme.typography.bodyLarge, color = BeamlyColors.Muted)
                Text(
                    state.deviceName,
                    style = MaterialTheme.typography.headlineMedium,
                    color = BeamlyColors.OnSurface,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.height(24.dp))
                Text(stringResource(R.string.label_address), style = MaterialTheme.typography.bodyLarge, color = BeamlyColors.Muted)
                Text(
                    state.address?.let { "$it:${state.port}" } ?: stringResource(R.string.no_network),
                    style = MaterialTheme.typography.headlineSmall,
                    color = if (state.address != null) BeamlyColors.OnSurface else BeamlyColors.Warning
                )
                Spacer(Modifier.height(32.dp))
                Text(
                    stringResource(R.string.same_network_hint),
                    style = MaterialTheme.typography.bodyMedium,
                    color = BeamlyColors.Muted
                )
                state.address?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        stringResource(R.string.cli_hint, it),
                        style = MaterialTheme.typography.bodySmall,
                        color = BeamlyColors.Muted.copy(alpha = 0.7f)
                    )
                }
            }
        }
    }
    Text(
        "v${BuildConfig.VERSION_NAME}",
        style = MaterialTheme.typography.bodySmall,
        color = BeamlyColors.Muted.copy(alpha = 0.5f),
        modifier = Modifier.align(Alignment.BottomEnd).padding(horizontal = 64.dp, vertical = 24.dp)
    )
}

@Composable
fun ConnectingScreen(state: ReceiverUiState.Connecting) = FullScreenBackground {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        BreathingLogo()
        Spacer(Modifier.height(36.dp))
        Text(
            stringResource(R.string.connecting_to, state.sender),
            style = MaterialTheme.typography.headlineSmall,
            color = BeamlyColors.OnSurface,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
fun ErrorScreen(state: ReceiverUiState.Failed, onRetry: () -> Unit) = FullScreenBackground {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Column(
        Modifier.fillMaxSize().then(SafeArea),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Image(
            painterResource(R.drawable.ic_warning),
            contentDescription = null,
            colorFilter = ColorFilter.tint(BeamlyColors.Error),
            modifier = Modifier.size(72.dp)
        )
        Spacer(Modifier.height(24.dp))
        Text(stringResource(R.string.error_title), style = MaterialTheme.typography.headlineLarge, color = BeamlyColors.OnSurface)
        Spacer(Modifier.height(12.dp))
        Text(
            if (state.portInUse) {
                stringResource(R.string.error_port_in_use, app.beamly.tv.net.Protocol.PORT)
            } else {
                stringResource(R.string.error_generic, state.detail)
            },
            style = MaterialTheme.typography.titleMedium,
            color = BeamlyColors.Muted,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 720.dp)
        )
        Spacer(Modifier.height(36.dp))
        Button(onClick = onRetry, modifier = Modifier.focusRequester(focus)) {
            Text(stringResource(R.string.retry))
        }
    }
}

/** Stream details, shown when OK is pressed while streaming. */
@Composable
fun StreamInfoPanel(state: ReceiverUiState.Streaming, modifier: Modifier = Modifier) {
    Panel(modifier.width(520.dp)) {
        Column(Modifier.padding(28.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AppLogo(40.dp)
                Spacer(Modifier.width(14.dp))
                Text(
                    stringResource(R.string.mirroring_from, state.sender),
                    style = MaterialTheme.typography.titleLarge,
                    color = BeamlyColors.OnSurface,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Spacer(Modifier.height(20.dp))
            InfoRow(stringResource(R.string.info_resolution), "${state.videoWidth} × ${state.videoHeight}", Modifier.fillMaxWidth())
            Spacer(Modifier.height(10.dp))
            InfoRow(stringResource(R.string.info_frame_rate), stringResource(R.string.info_fps, state.fps), Modifier.fillMaxWidth())
            Spacer(Modifier.height(10.dp))
            InfoRow(stringResource(R.string.info_bitrate), stringResource(R.string.info_mbps, state.mbps), Modifier.fillMaxWidth())
            Spacer(Modifier.height(10.dp))
            InfoRow(
                stringResource(R.string.info_audio),
                stringResource(if (state.audio) R.string.info_audio_on else R.string.info_audio_off),
                Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(20.dp))
            Text(stringResource(R.string.info_hint), style = MaterialTheme.typography.bodySmall, color = BeamlyColors.Muted)
        }
    }
}

/** Volume bar mirroring the Mac's volume. */
@Composable
fun VolumePanel(volume: Float, muted: Boolean, modifier: Modifier = Modifier) {
    Panel(modifier) {
        Row(Modifier.padding(horizontal = 24.dp, vertical = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(
                painterResource(if (muted || volume <= 0f) R.drawable.ic_volume_off else R.drawable.ic_volume),
                contentDescription = stringResource(R.string.volume),
                colorFilter = ColorFilter.tint(BeamlyColors.OnSurface),
                modifier = Modifier.size(28.dp)
            )
            Spacer(Modifier.width(16.dp))
            Box(
                Modifier.width(220.dp).height(8.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(BeamlyColors.OnSurface.copy(alpha = 0.15f))
            ) {
                Box(
                    Modifier.fillMaxHeight()
                        .fillMaxWidth(if (muted) 0f else volume)
                        .clip(RoundedCornerShape(4.dp))
                        .background(if (muted) BeamlyColors.Muted else BeamlyColors.Blue)
                )
            }
            Spacer(Modifier.width(16.dp))
            Text(
                if (muted) stringResource(R.string.volume_muted) else "${(volume * 100).roundToInt()}",
                style = MaterialTheme.typography.titleMedium,
                color = BeamlyColors.OnSurface,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.widthIn(min = 44.dp)
            )
        }
    }
}

/** Short on-screen message (connected, press BACK again, ...). */
@Composable
fun Toast(text: String, modifier: Modifier = Modifier) {
    Panel(modifier) {
        Text(
            text,
            style = MaterialTheme.typography.titleMedium,
            color = BeamlyColors.OnSurface,
            modifier = Modifier.padding(horizontal = 28.dp, vertical = 14.dp)
        )
    }
}

@Composable
private fun BreathingLogo() {
    val transition = rememberInfiniteTransition(label = "breathing")
    val scale by transition.animateFloat(
        initialValue = 0.94f,
        targetValue = 1.04f,
        animationSpec = infiniteRepeatable(tween(1100), RepeatMode.Reverse),
        label = "scale"
    )
    val alpha by transition.animateFloat(0.75f, 1f, infiniteRepeatable(tween(1100), RepeatMode.Reverse), label = "alpha")
    AppLogo(112.dp, Modifier.scale(scale).alpha(alpha))
}

@Composable
private fun noticeText(notice: Notice): String = stringResource(
    when (notice) {
        Notice.SENDER_STOPPED -> R.string.notice_sender_stopped
        Notice.CONNECTION_LOST -> R.string.notice_connection_lost
        Notice.PROTOCOL_ERROR -> R.string.notice_protocol_error
        Notice.INCOMPATIBLE_VERSION -> R.string.notice_incompatible_version
    }
)
