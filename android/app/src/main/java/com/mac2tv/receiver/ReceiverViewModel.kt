package com.mac2tv.receiver

import android.app.Application
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.view.Surface
import androidx.lifecycle.AndroidViewModel
import com.mac2tv.receiver.media.VideoDecoder
import com.mac2tv.receiver.net.DeviceInfo
import com.mac2tv.receiver.net.EndReason
import com.mac2tv.receiver.net.NsdAdvertiser
import com.mac2tv.receiver.net.Protocol
import com.mac2tv.receiver.net.StreamServer
import com.mac2tv.receiver.net.StreamStats
import com.mac2tv.receiver.net.VideoConfig
import com.mac2tv.receiver.net.VolumeState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.IOException
import java.net.BindException

/** Thông báo hiển thị trên màn hình chờ sau khi một phiên kết thúc. */
enum class Notice { SENDER_STOPPED, CONNECTION_LOST, PROTOCOL_ERROR }

sealed interface ReceiverUiState {
    data object Starting : ReceiverUiState

    data class Waiting(
        val deviceName: String,
        val address: String?,
        val port: Int,
        val notice: Notice? = null,
    ) : ReceiverUiState

    data class Connecting(val sender: String) : ReceiverUiState

    data class Streaming(
        val sender: String,
        val videoWidth: Int,
        val videoHeight: Int,
        val fps: Float = 0f,
        val mbps: Float = 0f,
        val audio: Boolean = false,
    ) : ReceiverUiState

    data class Failed(val portInUse: Boolean, val detail: String) : ReceiverUiState
}

class ReceiverViewModel(app: Application) : AndroidViewModel(app), StreamServer.Listener {

    private val _state = MutableStateFlow<ReceiverUiState>(ReceiverUiState.Starting)
    val state: StateFlow<ReceiverUiState> = _state.asStateFlow()

    /** Âm lượng Mac để hiện thanh âm lượng trên TV; [VolumeHud.seq] tăng mỗi lần Mac đổi âm lượng. */
    data class VolumeHud(val volume: Float, val muted: Boolean, val seq: Int)

    private val _volumeHud = MutableStateFlow<VolumeHud?>(null)
    val volumeHud: StateFlow<VolumeHud?> = _volumeHud.asStateFlow()

    private val decoder = VideoDecoder(::onFrameRendered)
    private val server = StreamServer(Protocol.PORT, decoder, this)
    private val nsd = NsdAdvertiser(app)
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)

    /** Thông tin phiên đang hoạt động; chỉ sự kiện của phiên này mới được xử lý. */
    private data class Session(val id: Long, val sender: String, val config: VideoConfig? = null)

    @Volatile private var session: Session? = null
    @Volatile private var firstFrameShown = false
    private var lastNotice: Notice? = null
    private var networkCallbackRegistered = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = refreshWaiting()
        override fun onLost(network: Network) = refreshWaiting()
    }

    fun start() {
        server.start()
        if (!networkCallbackRegistered) {
            runCatching { connectivity?.registerDefaultNetworkCallback(networkCallback) }
                .onSuccess { networkCallbackRegistered = true }
        }
    }

    fun stop() {
        server.stop()
        nsd.unregister()
        if (networkCallbackRegistered) {
            runCatching { connectivity?.unregisterNetworkCallback(networkCallback) }
            networkCallbackRegistered = false
        }
        session = null
        _state.value = ReceiverUiState.Starting
    }

    fun retry() {
        stop()
        start()
    }

    fun setSurface(surface: Surface?) = decoder.setSurface(surface)

    fun dismissNotice() {
        lastNotice = null
        _state.update { if (it is ReceiverUiState.Waiting) it.copy(notice = null) else it }
    }

    override fun onCleared() = stop()

    // region StreamServer.Listener (gọi từ luồng IO)

    override fun onListening() {
        nsd.register(DeviceInfo.deviceName(getApplication()), Protocol.PORT)
        showWaiting()
    }

    override fun onServerError(error: IOException) {
        _state.value = ReceiverUiState.Failed(
            portInUse = error is BindException,
            detail = error.message ?: error.javaClass.simpleName,
        )
    }

    override fun onSessionStarted(sessionId: Long, remoteAddress: String) {
        session = Session(sessionId, remoteAddress)
        firstFrameShown = false
        _volumeHud.value = null
        _state.value = ReceiverUiState.Connecting(remoteAddress)
    }

    override fun onSenderName(sessionId: Long, name: String) {
        val s = session?.takeIf { it.id == sessionId && name.isNotEmpty() } ?: return
        session = s.copy(sender = name)
        _state.update {
            when (it) {
                is ReceiverUiState.Connecting -> it.copy(sender = name)
                is ReceiverUiState.Streaming -> it.copy(sender = name)
                else -> it
            }
        }
    }

    override fun onVideoConfig(sessionId: Long, config: VideoConfig) {
        val s = session?.takeIf { it.id == sessionId } ?: return
        session = s.copy(config = config)
        _state.update {
            if (it is ReceiverUiState.Streaming) it.copy(videoWidth = config.width, videoHeight = config.height) else it
        }
    }

    override fun onStats(sessionId: Long, stats: StreamStats) {
        if (session?.id != sessionId) return
        _state.update {
            if (it is ReceiverUiState.Streaming) it.copy(fps = stats.fps, mbps = stats.mbps, audio = stats.audio) else it
        }
    }

    override fun onVolume(sessionId: Long, volume: VolumeState) {
        if (session?.id != sessionId) return
        _volumeHud.update { VolumeHud(volume.volume, volume.muted, (it?.seq ?: 0) + 1) }
    }

    override fun onSessionEnded(sessionId: Long, reason: EndReason) {
        if (session?.id != sessionId) return
        session = null
        lastNotice = when (reason) {
            EndReason.SENDER_STOPPED -> Notice.SENDER_STOPPED
            EndReason.CONNECTION_LOST -> Notice.CONNECTION_LOST
            EndReason.PROTOCOL_ERROR -> Notice.PROTOCOL_ERROR
            EndReason.CLOSED_LOCALLY -> null
        }
        if (server.isRunning) showWaiting()
    }

    // endregion

    /** Gọi trên luồng decoder mỗi khi một khung được hiển thị. */
    private fun onFrameRendered() {
        if (firstFrameShown) return
        val s = session ?: return
        val config = s.config ?: return
        firstFrameShown = true
        _state.value = ReceiverUiState.Streaming(s.sender, config.width, config.height)
    }

    private fun showWaiting() {
        val app = getApplication<Application>()
        _state.value = ReceiverUiState.Waiting(
            deviceName = DeviceInfo.deviceName(app),
            address = DeviceInfo.localIpv4(app),
            port = Protocol.PORT,
            notice = lastNotice,
        )
    }

    private fun refreshWaiting() {
        if (_state.value is ReceiverUiState.Waiting) showWaiting()
    }
}
