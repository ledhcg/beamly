package com.mac2tv.receiver.net

import android.util.Log
import com.mac2tv.receiver.media.AudioPlayer
import com.mac2tv.receiver.media.VideoDecoder
import java.io.IOException
import java.net.ProtocolException
import java.net.Socket
import java.net.SocketTimeoutException

/** Lý do một phiên kết thúc. */
enum class EndReason {
    /** Mac chủ động dừng (gói BYE). */
    SENDER_STOPPED,

    /** Mất kết nối: socket đóng bất thường hoặc quá [Protocol.READ_TIMEOUT_MS] không có dữ liệu. */
    CONNECTION_LOST,

    /** Dữ liệu sai giao thức. */
    PROTOCOL_ERROR,

    /** TV đóng phiên (kết nối mới thay thế, hoặc app dừng). */
    CLOSED_LOCALLY,
}

data class StreamStats(val fps: Float, val mbps: Float, val audio: Boolean)

/** Một kết nối từ Mac. [run] chặn luồng gọi cho tới khi phiên kết thúc. */
class StreamSession(
    val id: Long,
    private val socket: Socket,
    private val input: java.io.InputStream,
    private val decoder: VideoDecoder,
    private val listener: Listener,
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
                    PacketType.HELLO ->
                        listener.onSenderName(id, String(packet.payload, 0, packet.length, Charsets.UTF_8).trim())
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
            if (closedLocally) EndReason.CLOSED_LOCALLY else EndReason.CONNECTION_LOST.also {
                Log.i(TAG, "Session $id: connection lost ($e)")
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
