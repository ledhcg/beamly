package com.mac2tv.receiver.net

import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.net.ProtocolException
import java.nio.ByteBuffer

/**
 * Giao thức mac2tv (big-endian). Mỗi gói: `u32 len | u8 type | u64 ptsMicros | payload[len]`.
 * Phải khớp với mac/Engine.swift.
 */
object Protocol {
    const val PORT = 7878
    const val SERVICE_TYPE = "_mac2tv._tcp"
    const val HEADER_SIZE = 13
    const val MAX_PAYLOAD = 32 * 1024 * 1024

    /** Mac gửi ping mỗi giây; im lặng lâu hơn mức này coi như mất kết nối. */
    const val READ_TIMEOUT_MS = 4_000

    /** Định dạng audio cố định: PCM s16le, 48 kHz, stereo, interleaved. */
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

    /** UTF-8: tên máy Mac, gửi ngay sau khi kết nối. */
    HELLO(6),

    /** `f32 volume (0..1) | f32 gain (0..1) | u8 muted`: âm lượng Mac, để TV phát như một thiết bị âm thanh của Mac. */
    VOLUME(7);

    companion object {
        private val byCode = entries.associateBy { it.code }
        fun of(code: Int): PacketType? = byCode[code]
    }
}

/**
 * Một gói đã đọc. [payload] là buffer dùng lại của [PacketReader]:
 * chỉ hợp lệ tới lần gọi [PacketReader.next] tiếp theo, chỉ đọc [length] byte đầu.
 */
class Packet internal constructor(
    val type: PacketType?,
    val ptsUs: Long,
    val payload: ByteArray,
    val length: Int,
) {
    fun copyPayload(): ByteArray = payload.copyOf(length)
}

/** Đọc tuần tự các gói từ luồng, dùng lại một buffer để tránh cấp phát mỗi khung hình. */
class PacketReader(input: InputStream, initialCapacity: Int = 512 * 1024) {
    private val data = DataInputStream(input)
    private var buffer = ByteArray(initialCapacity)

    /** @return gói tiếp theo, hoặc `null` khi luồng kết thúc gọn gàng ở ranh giới gói. */
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

/** Âm lượng của Mac (gói VOLUME). [volume] là vị trí thanh âm lượng macOS, [gain] là hệ số khuếch đại tuyến tính. */
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

/** Cấu hình video (gói CONFIG): kích thước + SPS/PPS của H.264. */
class VideoConfig(val width: Int, val height: Int, val sps: ByteArray, val pps: ByteArray) {

    override fun equals(other: Any?): Boolean =
        other is VideoConfig && width == other.width && height == other.height &&
            sps.contentEquals(other.sps) && pps.contentEquals(other.pps)

    override fun hashCode(): Int =
        ((width * 31 + height) * 31 + sps.contentHashCode()) * 31 + pps.contentHashCode()

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
