package app.beamly.tv.net

import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.ProtocolException
import java.nio.ByteBuffer

/**
 * Beamly wire protocol (big-endian). Handshake packets: `u32 length | u8 type | u64 ptsMicros | payload[length]`;
 * afterwards AES-256-GCM records: `u32 length | ciphertext`.
 * Normative spec: docs/PROTOCOL.md. Sender: macos/Sources/BeamlyKit/Protocol.swift.
 */
object Protocol {
    /** Bumped on any incompatible change; the receiver rejects senders with a different version. */
    const val VERSION = 2
    const val PORT = 7878
    const val SERVICE_TYPE = "_beamly._tcp"
    const val HEADER_SIZE = 13
    const val MAX_PAYLOAD = 32 * 1024 * 1024

    /** The sender pings every second; silence longer than this means the connection is lost. */
    const val READ_TIMEOUT_MS = 4_000

    /** The receiver gives up on pairing after this long. */
    const val PAIRING_TIMEOUT_MS = 120_000L

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

    /** `u16 version | u8[16] deviceId | u8[65] identityKey | u8[65] ephemeralKey | UTF-8 name`; always the first packet. */
    HELLO(6),

    /** `f32 volume (0..1) | f32 gain (0..1) | u8 muted`: the sender's volume, so the TV behaves like its audio output. */
    VOLUME(7),

    /** TV → Mac: `u8 flags | u8[65] identityKey | u8[65] ephemeralKey | UTF-8 name`. */
    SERVER_HELLO(8),

    /** Mac → TV, empty: start pairing. */
    PAIR_START(9),

    /** TV → Mac: `u8[32]` commitment to the TV's nonce. */
    PAIR_COMMIT(10),

    /** Both directions: `u8[32]` nonce. */
    PAIR_NONCE(11),

    /** Both directions: `u8 accepted`. */
    PAIR_CONFIRM(12),

    /** Mac → TV, empty: the last plaintext packet; both directions are encrypted afterwards. */
    SESSION_START(13),

    /** TV → Mac, encrypted and empty: the session is accepted. */
    READY(14),

    /** TV → Mac: `u8 reason`, see [RejectReason]. */
    REJECT(15)
    ;

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

/**
 * Reads packets sequentially, reusing buffers to avoid an allocation per frame. Reads plaintext packets until
 * [cipher] is set, then encrypted records.
 */
class PacketReader(input: InputStream, initialCapacity: Int = 512 * 1024) {
    private val data = DataInputStream(input)
    private var buffer = ByteArray(initialCapacity)
    private var ciphertext = ByteArray(0)

    /** Decrypts incoming records once set (after SESSION_START). */
    var cipher: RecordCipher? = null

    /** @return the next packet, or `null` when the stream ends cleanly at a packet boundary. */
    fun next(): Packet? {
        val length = try {
            data.readInt()
        } catch (_: EOFException) {
            return null
        }
        val recordCipher = cipher ?: return readPlaintext(length)
        if (length < RecordCipher.OVERHEAD || length > Protocol.MAX_PAYLOAD + RecordCipher.OVERHEAD) {
            throw ProtocolException("Invalid record length: $length")
        }
        if (ciphertext.size < length) ciphertext = ByteArray(maxOf(length, ciphertext.size * 2))
        data.readFully(ciphertext, 0, length)
        ensureCapacity(length)
        val plainLength = recordCipher.open(ciphertext, length, buffer)
        val header = ByteBuffer.wrap(buffer, 0, 9)
        val code = header.get().toInt() and 0xff
        val pts = header.long
        val payloadLength = plainLength - 9
        System.arraycopy(buffer, 9, buffer, 0, payloadLength)
        return Packet(PacketType.of(code), pts, buffer, payloadLength)
    }

    private fun readPlaintext(length: Int): Packet {
        val code = data.readUnsignedByte()
        val pts = data.readLong()
        if (length < 0 || length > Protocol.MAX_PAYLOAD) {
            throw ProtocolException("Invalid payload length: $length")
        }
        ensureCapacity(length)
        data.readFully(buffer, 0, length)
        return Packet(PacketType.of(code), pts, buffer, length)
    }

    private fun ensureCapacity(length: Int) {
        if (buffer.size < length) buffer = ByteArray(maxOf(length, buffer.size * 2))
    }
}

/** Writes packets from the session thread: plaintext until [cipher] is set, then encrypted records. */
class PacketWriter(private val output: OutputStream) {
    /** Encrypts outgoing records once set (after SESSION_START). */
    var cipher: RecordCipher? = null

    fun write(type: PacketType, payload: ByteArray = ByteArray(0)) {
        val recordCipher = cipher
        val bytes = if (recordCipher != null) {
            recordCipher.seal(type.code, 0, payload)
        } else {
            ByteBuffer.allocate(Protocol.HEADER_SIZE + payload.size).putInt(payload.size).put(type.code.toByte()).putLong(0)
                .put(payload).array()
        }
        output.write(bytes)
        output.flush()
    }
}

/** Reasons carried by [PacketType.REJECT]. */
enum class RejectReason(val code: Int) {
    NOT_PAIRED(1),
    PAIRING_DECLINED(2),
    PAIRING_TIMED_OUT(3)
}

/**
 * First packet of every connection (HELLO). Only [protocolVersion] is meaningful when it differs from
 * [Protocol.VERSION]; the other fields are then empty.
 */
class Hello(
    val protocolVersion: Int,
    val deviceId: ByteArray,
    val identityKey: ByteArray,
    val ephemeralKey: ByteArray,
    val deviceName: String
) {
    companion object {
        private const val DEVICE_ID_LENGTH = 16

        fun parse(payload: ByteArray, length: Int): Hello {
            if (length < 2) throw ProtocolException("Truncated hello packet")
            val version = ((payload[0].toInt() and 0xff) shl 8) or (payload[1].toInt() and 0xff)
            if (version != Protocol.VERSION) return Hello(version, ByteArray(0), ByteArray(0), ByteArray(0), "")
            val keys = SessionCrypto.PUBLIC_KEY_LENGTH
            val nameOffset = 2 + DEVICE_ID_LENGTH + 2 * keys
            if (length < nameOffset) throw ProtocolException("Truncated hello packet")
            return Hello(
                protocolVersion = version,
                deviceId = payload.copyOfRange(2, 2 + DEVICE_ID_LENGTH),
                identityKey = payload.copyOfRange(2 + DEVICE_ID_LENGTH, 2 + DEVICE_ID_LENGTH + keys),
                ephemeralKey = payload.copyOfRange(2 + DEVICE_ID_LENGTH + keys, nameOffset),
                deviceName = String(payload, nameOffset, length - nameOffset, Charsets.UTF_8).trim()
            )
        }
    }
}

/** SERVER_HELLO payload: `u8 flags | u8[65] identityKey | u8[65] ephemeralKey | UTF-8 name`. */
object ServerHello {
    fun encode(knowsSender: Boolean, identityKey: ByteArray, ephemeralKey: ByteArray, name: String): ByteArray =
        byteArrayOf(if (knowsSender) 1 else 0) + identityKey + ephemeralKey + name.toByteArray(Charsets.UTF_8)
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
