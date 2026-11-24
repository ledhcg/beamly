package app.beamly.tv.ui

import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.beamly.tv.R
import app.beamly.tv.ReceiverUiState
import app.beamly.tv.ReceiverViewModel
import kotlinx.coroutines.delay

private val InfoKeys = setOf(Key.DirectionCenter, Key.Enter, Key.NumPadEnter, Key.Info, Key.Menu)

@Composable
fun ReceiverApp(viewModel: ReceiverViewModel, onExit: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val streaming = state as? ReceiverUiState.Streaming

    var showInfo by remember { mutableStateOf(false) }
    var exitArmed by remember { mutableStateOf(false) }
    var showConnectedToast by remember { mutableStateOf(false) }

    // Keep the screen on only while streaming.
    val view = LocalView.current
    DisposableEffect(streaming != null) {
        view.keepScreenOn = streaming != null
        onDispose { view.keepScreenOn = false }
    }

    // While streaming, BACK must be pressed twice to exit, to avoid accidental exits.
    BackHandler(enabled = streaming != null) {
        if (exitArmed) onExit() else exitArmed = true
    }
    LaunchedEffect(exitArmed) {
        if (exitArmed) {
            delay(2_500)
            exitArmed = false
        }
    }
    LaunchedEffect(showInfo) {
        if (showInfo) {
            delay(8_000)
            showInfo = false
        }
    }
    LaunchedEffect(streaming?.sender) {
        showInfo = false
        if (streaming != null) {
            showConnectedToast = true
            delay(4_000)
            showConnectedToast = false
        }
    }

    val focus = remember { FocusRequester() }
    LaunchedEffect(state::class) {
        if (state !is ReceiverUiState.Failed) runCatching { focus.requestFocus() }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(focus)
            .focusable()
            .onPreviewKeyEvent { event ->
                if (streaming != null && event.type == KeyEventType.KeyDown && event.key in InfoKeys) {
                    showInfo = !showInfo
                    true
                } else {
                    false
                }
            },
        contentAlignment = Alignment.Center
    ) {
        // The SurfaceView stays in the hierarchy so its surface is ready before the first frame arrives.
        VideoSurface(
            aspectRatio = streaming?.let { it.videoWidth.toFloat() / it.videoHeight },
            onSurfaceChanged = viewModel::setSurface
        )

        when (val s = state) {
            ReceiverUiState.Starting -> StartingScreen()
            is ReceiverUiState.Waiting -> WaitingScreen(s, onNoticeShown = viewModel::dismissNotice)
            is ReceiverUiState.Connecting -> ConnectingScreen(s)
            is ReceiverUiState.Failed -> ErrorScreen(s, onRetry = viewModel::retry)
            is ReceiverUiState.Streaming -> Unit
        }

        if (streaming != null) {
            VolumeOverlay(viewModel, Modifier.align(Alignment.TopEnd).padding(top = 40.dp, end = 48.dp))
            AnimatedVisibility(
                visible = exitArmed,
                enter = fadeIn() + slideInVertically { it },
                exit = fadeOut() + slideOutVertically { it },
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 40.dp)
            ) {
                Toast(stringResource(R.string.press_back_again))
            }
            AnimatedVisibility(
                visible = showInfo,
                enter = fadeIn() + slideInHorizontally { -it / 4 },
                exit = fadeOut() + slideOutHorizontally { -it / 4 },
                modifier = Modifier.align(Alignment.TopStart).padding(48.dp)
            ) {
                StreamInfoPanel(streaming)
            }
            AnimatedVisibility(
                visible = showConnectedToast && !showInfo,
                enter = fadeIn() + slideInVertically { -it },
                exit = fadeOut() + slideOutVertically { -it },
                modifier = Modifier.align(Alignment.TopCenter).padding(top = 32.dp)
            ) {
                Toast(stringResource(R.string.mirroring_from, streaming.sender) + "  ·  " + stringResource(R.string.press_ok_for_info))
            }
        }
    }
}

/** Shows the volume bar for a few seconds whenever the Mac's volume changes (not for the initial sync). */
@Composable
private fun VolumeOverlay(viewModel: ReceiverViewModel, modifier: Modifier) {
    val hud by viewModel.volumeHud.collectAsStateWithLifecycle()
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(hud?.seq) {
        if ((hud?.seq ?: 0) > 1) {
            visible = true
            delay(2_500)
            visible = false
        }
    }
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn() + slideInHorizontally { it / 3 },
        exit = fadeOut() + slideOutHorizontally { it / 3 },
        modifier = modifier
    ) {
        hud?.let { VolumePanel(it.volume, it.muted) }
    }
}

@Composable
private fun VideoSurface(aspectRatio: Float?, onSurfaceChanged: (Surface?) -> Unit) {
    val callback by rememberUpdatedState(onSurfaceChanged)
    val holderCallback = remember {
        object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = callback(holder.surface)
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
            override fun surfaceDestroyed(holder: SurfaceHolder) = callback(null)
        }
    }
    AndroidView(
        factory = { context -> SurfaceView(context).apply { holder.addCallback(holderCallback) } },
        modifier = if (aspectRatio != null) Modifier.aspectRatio(aspectRatio) else Modifier.fillMaxSize()
    )
}
