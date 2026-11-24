package app.beamly.tv.net

import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.net.ProtocolException
import java.nio.ByteBuffer

/**
 * Beamly wire protocol (big-endian). Each packet: `u32 length | u8 type | u64 ptsMicros | payload[length]`.
 * Normative spec: docs/PROTOCOL.md. Sender: macos/Sources/BeamlyKit/Protocol.swift.
 */
object Protocol {
    /** Bumped on any incompatible change; the receiver rejects senders with a different version. */
    const val VERSION = 1
    const val PORT = 7878
    const val SERVICE_TYPE = "_beamly._tcp"
    const val HEADER_SIZE = 13
    const val MAX_PAYLOAD = 32 * 1024 * 1024

    /** The sender pings every second; silence longer than this means the connection is lost. */
    const val READ_TIMEOUT_MS = 4_000

    /** Fixed audio format: PCM s16le, 48 kHz, stereo, interleaved. */
    const val AUDIO_SAMPLE_RATE = 48_000
    const val AUDIO_BYTES_PER_FRAME = 4
}

enum class PacketType(val code: Int) {
    CONFIG(0),
    KEY_FRAME(1),
    FRAME(2),
    AUDIO(3),
    BYE(4),
    PING(5),

    /** `u16 protocolVersion | UTF-8 device name`; always the first packet. */
    HELLO(6),

    /** `f32 volume (0..1) | f32 gain (0..1) | u8 muted`: the sender's volume, so the TV behaves like its audio output. */
    VOLUME(7);

    companion object {
        private val byCode = entries.associateBy { it.code }
        fun of(code: Int): PacketType? = byCode[code]
    }
}

/**
 * A decoded packet. [payload] is [PacketReader]'s reusable buffer: it is valid only until the next
 * call to [PacketReader.next], and only the first [length] bytes belong to this packet.
 */
class Packet internal constructor(val type: PacketType?, val ptsUs: Long, val payload: ByteArray, val length: Int) {
    fun copyPayload(): ByteArray = payload.copyOf(length)
}

/** Reads packets sequentially, reusing one buffer to avoid an allocation per frame. */
class PacketReader(input: InputStream, initialCapacity: Int = 512 * 1024) {
    private val data = DataInputStream(input)
    private var buffer = ByteArray(initialCapacity)

    /** @return the next packet, or `null` when the stream ends cleanly at a packet boundary. */
    fun next(): Packet? {
        val length = try {
            data.readInt()
        } catch (_: EOFException) {
            return null
        }
        val code = data.readUnsignedByte()
        val pts = data.readLong()
        if (length < 0 || length > Protocol.MAX_PAYLOAD) {
            throw ProtocolException("Invalid payload length: $length")
        }
        if (buffer.size < length) {
            buffer = ByteArray(maxOf(length, buffer.size * 2))
        }
        data.readFully(buffer, 0, length)
        return Packet(PacketType.of(code), pts, buffer, length)
    }
}

/** First packet of every connection (HELLO). */
data class Hello(val protocolVersion: Int, val deviceName: String) {
    companion object {
        fun parse(payload: ByteArray, length: Int): Hello {
            if (length < 2) throw ProtocolException("Truncated hello packet")
            val version = ((payload[0].toInt() and 0xff) shl 8) or (payload[1].toInt() and 0xff)
            return Hello(version, String(payload, 2, length - 2, Charsets.UTF_8).trim())
        }
    }
}

/** Sender volume (VOLUME packet). [volume] is the macOS slider position, [gain] the linear gain. */
data class VolumeState(val volume: Float, val gain: Float, val muted: Boolean) {
    companion object {
        fun parse(payload: ByteArray, length: Int): VolumeState {
            if (length < 9) throw ProtocolException("Truncated volume packet")
            val b = ByteBuffer.wrap(payload, 0, length)
            val volume = b.float.coerceIn(0f, 1f)
            val gain = b.float.coerceIn(0f, 1f)
            val muted = b.get().toInt() != 0
            return VolumeState(volume, if (muted) 0f else gain, muted)
        }
    }
}

/** Video configuration (CONFIG packet): size and H.264 SPS/PPS. */
class VideoConfig(val width: Int, val height: Int, val sps: ByteArray, val pps: ByteArray) {

    override fun equals(other: Any?): Boolean = other is VideoConfig &&
        width == other.width &&
        height == other.height &&
        sps.contentEquals(other.sps) &&
        pps.contentEquals(other.pps)

    override fun hashCode(): Int = ((width * 31 + height) * 31 + sps.contentHashCode()) * 31 + pps.contentHashCode()

    override fun toString(): String = "VideoConfig(${width}x$height, sps=${sps.size}B, pps=${pps.size}B)"

    companion object {
        /** payload: `u16 width | u16 height | u16 spsLen | sps | u16 ppsLen | pps` */
        fun parse(payload: ByteArray, length: Int = payload.size): VideoConfig {
            try {
                val b = ByteBuffer.wrap(payload, 0, length)
                val width = b.short.toInt() and 0xffff
                val height = b.short.toInt() and 0xffff
                val sps = ByteArray(b.short.toInt() and 0xffff).also { b.get(it) }
                val pps = ByteArray(b.short.toInt() and 0xffff).also { b.get(it) }
                if (width == 0 || height == 0 || sps.isEmpty() || pps.isEmpty()) {
                    throw ProtocolException("Invalid video config: ${width}x$height")
                }
                return VideoConfig(width, height, sps, pps)
            } catch (e: java.nio.BufferUnderflowException) {
                throw ProtocolException("Truncated video config").apply { initCause(e) }
            }
        }
    }
}
