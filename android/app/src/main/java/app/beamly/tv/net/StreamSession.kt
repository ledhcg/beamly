package app.beamly.tv.net

import android.util.Log
import app.beamly.tv.media.AudioPlayer
import app.beamly.tv.media.VideoDecoder
import java.io.IOException
import java.net.ProtocolException
import java.net.Socket
import java.net.SocketTimeoutException

/** Why a session ended. */
enum class EndReason {
    /** The sender stopped on purpose (BYE packet). */
    SENDER_STOPPED,

    /** The socket closed unexpectedly or no data arrived for [Protocol.READ_TIMEOUT_MS]. */
    CONNECTION_LOST,

    /** The sender violated the protocol. */
    PROTOCOL_ERROR,

    /** The sender speaks a different protocol version; one of the apps needs an update. */
    INCOMPATIBLE_VERSION,

    /** The receiver closed the session (replaced by a new connection, or the app stopped). */
    CLOSED_LOCALLY
}

data class StreamStats(val fps: Float, val mbps: Float, val audio: Boolean)

/** One connection from a sender. [run] blocks the calling thread until the session ends. */
class StreamSession(
    val id: Long,
    private val socket: Socket,
    private val input: java.io.InputStream,
    private val decoder: VideoDecoder,
    private val listener: Listener
) {
    interface Listener {
        fun onSenderName(sessionId: Long, name: String)
        fun onVideoConfig(sessionId: Long, config: VideoConfig)
        fun onStats(sessionId: Long, stats: StreamStats)
        fun onVolume(sessionId: Long, volume: VolumeState)
    }

    val remoteAddress: String = socket.inetAddress?.hostAddress?.substringBefore('%') ?: "?"

    @Volatile private var closedLocally = false

    fun close() {
        closedLocally = true
        runCatching { socket.close() }
    }

    fun run(): EndReason {
        val audio = AudioPlayer()
        var audioStarted = false
        var frames = 0
        var bytes = 0L
        var statsStart = System.nanoTime()
        decoder.reset()
        return try {
            socket.soTimeout = Protocol.READ_TIMEOUT_MS
            val reader = PacketReader(input)
            while (true) {
                val packet = reader.next() ?: return EndReason.CONNECTION_LOST
                bytes += Protocol.HEADER_SIZE + packet.length
                when (packet.type) {
                    PacketType.HELLO -> {
                        val hello = Hello.parse(packet.payload, packet.length)
                        if (hello.protocolVersion != Protocol.VERSION) {
                            Log.w(TAG, "Session $id: unsupported protocol version ${hello.protocolVersion}")
                            return EndReason.INCOMPATIBLE_VERSION
                        }
                        listener.onSenderName(id, hello.deviceName)
                    }
                    PacketType.CONFIG -> {
                        val config = VideoConfig.parse(packet.payload, packet.length)
                        decoder.configure(config)
                        listener.onVideoConfig(id, config)
                    }
                    PacketType.KEY_FRAME, PacketType.FRAME -> {
                        frames++
                        decoder.decode(packet.payload, packet.length, packet.ptsUs, packet.type == PacketType.KEY_FRAME)
                    }
                    PacketType.AUDIO -> {
                        if (!audioStarted) {
                            audio.start()
                            audioStarted = true
                        }
                        audio.enqueue(packet.copyPayload())
                    }
                    PacketType.VOLUME -> {
                        val volume = VolumeState.parse(packet.payload, packet.length)
                        audio.setGain(volume.gain)
                        listener.onVolume(id, volume)
                    }
                    PacketType.BYE -> return EndReason.SENDER_STOPPED
                    PacketType.PING, null -> Unit
                }

                val now = System.nanoTime()
                val elapsed = now - statsStart
                if (elapsed >= STATS_INTERVAL_NS) {
                    val seconds = elapsed / 1e9f
                    listener.onStats(id, StreamStats(frames / seconds, bytes * 8 / 1e6f / seconds, audioStarted))
                    frames = 0
                    bytes = 0
                    statsStart = now
                }
            }
            @Suppress("UNREACHABLE_CODE")
            EndReason.CONNECTION_LOST
        } catch (e: ProtocolException) {
            Log.w(TAG, "Session $id: protocol error", e)
            EndReason.PROTOCOL_ERROR
        } catch (_: SocketTimeoutException) {
            Log.i(TAG, "Session $id: timed out")
            EndReason.CONNECTION_LOST
        } catch (e: IOException) {
            if (closedLocally) {
                EndReason.CLOSED_LOCALLY
            } else {
                EndReason.CONNECTION_LOST.also {
                    Log.i(TAG, "Session $id: connection lost ($e)")
                }
            }
        } finally {
            audio.stop()
            decoder.reset()
            runCatching { socket.close() }
        }
    }

    private companion object {
        const val TAG = "StreamSession"
        const val STATS_INTERVAL_NS = 1_000_000_000L
    }
}
