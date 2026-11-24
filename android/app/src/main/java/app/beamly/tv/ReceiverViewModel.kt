package app.beamly.tv

import android.app.Application
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.view.Surface
import androidx.lifecycle.AndroidViewModel
import app.beamly.tv.media.VideoDecoder
import app.beamly.tv.net.DeviceInfo
import app.beamly.tv.net.EndReason
import app.beamly.tv.net.NsdAdvertiser
import app.beamly.tv.net.PairedMac
import app.beamly.tv.net.PairingStore
import app.beamly.tv.net.Protocol
import app.beamly.tv.net.StreamServer
import app.beamly.tv.net.StreamStats
import app.beamly.tv.net.VideoConfig
import app.beamly.tv.net.VolumeState
import java.io.IOException
import java.net.BindException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Message shown on the waiting screen after a session ends. */
enum class Notice {
    SENDER_STOPPED,
    CONNECTION_LOST,
    PROTOCOL_ERROR,
    INCOMPATIBLE_VERSION,
    NOT_PAIRED,
    PAIRING_DECLINED,
    PAIRING_CANCELLED,
    PAIRING_TIMED_OUT
}

sealed interface ReceiverUiState {
    data object Starting : ReceiverUiState

    data class Waiting(val deviceName: String, val address: String?, val port: Int, val notice: Notice? = null) : ReceiverUiState

    data class Connecting(val sender: String) : ReceiverUiState

    /** First connection from [macName]: the user compares [code] with the Mac. [accepted]: waiting for the Mac. */
    data class Pairing(val macName: String, val code: String, val accepted: Boolean = false) : ReceiverUiState

    data class Streaming(
        val sender: String,
        val videoWidth: Int,
        val videoHeight: Int,
        val fps: Float = 0f,
        val mbps: Float = 0f,
        val audio: Boolean = false
    ) : ReceiverUiState

    data class Failed(val portInUse: Boolean, val detail: String) : ReceiverUiState
}

class ReceiverViewModel(app: Application) :
    AndroidViewModel(app),
    StreamServer.Listener {

    private val _state = MutableStateFlow<ReceiverUiState>(ReceiverUiState.Starting)
    val state: StateFlow<ReceiverUiState> = _state.asStateFlow()

    /** Mac volume for the on-screen volume bar; [VolumeHud.seq] increases on every change. */
    data class VolumeHud(val volume: Float, val muted: Boolean, val seq: Int)

    private val _volumeHud = MutableStateFlow<VolumeHud?>(null)
    val volumeHud: StateFlow<VolumeHud?> = _volumeHud.asStateFlow()

    private val decoder = VideoDecoder(::onFrameRendered)
    private val pairing = PairingStore(app)
    private val server = StreamServer(Protocol.PORT, decoder, pairing, { DeviceInfo.deviceName(app) }, this)

    /** Macs allowed to stream to this TV. */
    val pairedMacs: StateFlow<List<PairedMac>> = pairing.pairedMacs
    private val nsd = NsdAdvertiser(app)
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)

    /** The active session; callbacks for any other session are ignored. */
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

    /** The TV user compared the pairing code: [accepted] if it matches the Mac's. */
    fun respondToPairing(accepted: Boolean) {
        val s = session ?: return
        server.respondToPairing(s.id, accepted)
        if (accepted) _state.update { if (it is ReceiverUiState.Pairing) it.copy(accepted = true) else it }
    }

    fun forgetMac(mac: PairedMac) = pairing.forget(mac)

    fun dismissNotice() {
        lastNotice = null
        _state.update { if (it is ReceiverUiState.Waiting) it.copy(notice = null) else it }
    }

    override fun onCleared() = stop()

    // region StreamServer.Listener (called on IO threads)

    override fun onListening() {
        nsd.register(DeviceInfo.deviceName(getApplication()), Protocol.PORT)
        showWaiting()
    }

    override fun onServerError(error: IOException) {
        _state.value = ReceiverUiState.Failed(
            portInUse = error is BindException,
            detail = error.message ?: error.javaClass.simpleName
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

    override fun onPairingRequest(sessionId: Long, macName: String, code: String) {
        if (session?.id != sessionId) return
        _state.value = ReceiverUiState.Pairing(macName, "${code.take(3)} ${code.drop(3)}")
    }

    override fun onPaired(sessionId: Long) {
        val s = session?.takeIf { it.id == sessionId } ?: return
        _state.value = ReceiverUiState.Connecting(s.sender)
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
            EndReason.INCOMPATIBLE_VERSION -> Notice.INCOMPATIBLE_VERSION
            EndReason.NOT_PAIRED -> Notice.NOT_PAIRED
            EndReason.PAIRING_DECLINED -> Notice.PAIRING_DECLINED
            EndReason.PAIRING_CANCELLED -> Notice.PAIRING_CANCELLED
            EndReason.PAIRING_TIMED_OUT -> Notice.PAIRING_TIMED_OUT
            EndReason.CLOSED_LOCALLY -> null
        }
        if (server.isRunning) showWaiting()
    }

    // endregion

    /** Called on the decoder thread every time a frame is rendered. */
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
            notice = lastNotice
        )
    }

    private fun refreshWaiting() {
        if (_state.value is ReceiverUiState.Waiting) showWaiting()
    }
}
