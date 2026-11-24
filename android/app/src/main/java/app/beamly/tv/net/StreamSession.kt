package app.beamly.tv.net

import android.util.Log
import app.beamly.tv.media.AudioPlayer
import app.beamly.tv.media.VideoDecoder
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.ProtocolException
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicReference

/** Why a session ended. */
enum class EndReason {
    /** The sender stopped on purpose (BYE packet). */
    SENDER_STOPPED,

    /** The socket closed unexpectedly or no data arrived for [Protocol.READ_TIMEOUT_MS]. */
    CONNECTION_LOST,

    /** The sender violated the protocol or failed authentication. */
    PROTOCOL_ERROR,

    /** The sender speaks a different protocol version; one of the apps needs an update. */
    INCOMPATIBLE_VERSION,

    /** The sender tried to start a session without being paired. */
    NOT_PAIRED,

    /** The user declined pairing on the TV. */
    PAIRING_DECLINED,

    /** The user cancelled pairing on the Mac. */
    PAIRING_CANCELLED,

    /** Nobody confirmed the pairing code in time. */
    PAIRING_TIMED_OUT,

    /** The receiver closed the session (replaced by a new connection, or the app stopped). */
    CLOSED_LOCALLY
}

data class StreamStats(val fps: Float, val mbps: Float, val audio: Boolean)

/** One connection from a sender. [run] blocks the calling thread until the session ends. */
class StreamSession(
    val id: Long,
    private val socket: Socket,
    private val input: InputStream,
    private val decoder: VideoDecoder,
    private val pairing: PairingStore,
    private val tvName: () -> String,
    private val listener: Listener
) {
    interface Listener {
        fun onSenderName(sessionId: Long, name: String)

        /** The user must compare [code] with the Mac's and call [StreamSession.respondToPairing]. */
        fun onPairingRequest(sessionId: Long, macName: String, code: String)

        /** Both users confirmed; the Mac is now paired. */
        fun onPaired(sessionId: Long)
        fun onVideoConfig(sessionId: Long, config: VideoConfig)
        fun onStats(sessionId: Long, stats: StreamStats)
        fun onVolume(sessionId: Long, volume: VolumeState)
    }

    private class Ended(val reason: EndReason) : Exception()

    val remoteAddress: String = socket.inetAddress?.hostAddress?.substringBefore('%') ?: "?"

    @Volatile private var closedLocally = false
    private val pairingDecision = AtomicReference<Boolean?>(null)

    fun close() {
        closedLocally = true
        runCatching { socket.close() }
    }

    /** The TV user's answer to [Listener.onPairingRequest]; picked up within about a second (the Mac pings every second). */
    fun respondToPairing(accepted: Boolean) {
        pairingDecision.compareAndSet(null, accepted)
    }

    fun run(): EndReason {
        decoder.reset()
        return try {
            socket.soTimeout = Protocol.READ_TIMEOUT_MS
            val reader = PacketReader(input)
            val writer = PacketWriter(BufferedOutputStream(socket.getOutputStream()))
            handshake(reader, writer)
            stream(reader)
        } catch (e: Ended) {
            e.reason
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
                EndReason.CONNECTION_LOST.also { Log.i(TAG, "Session $id: connection lost ($e)") }
            }
        } catch (e: java.security.GeneralSecurityException) {
            Log.w(TAG, "Session $id: key agreement failed", e)
            EndReason.PROTOCOL_ERROR
        } finally {
            decoder.reset()
            runCatching { socket.close() }
        }
    }

    // region Handshake (docs/PROTOCOL.md §6)

    private fun handshake(reader: PacketReader, writer: PacketWriter) {
        val first = reader.next() ?: throw Ended(EndReason.CONNECTION_LOST)
        if (first.type != PacketType.HELLO) throw ProtocolException("Expected HELLO, got ${first.type}")
        val hello = Hello.parse(first.payload, first.length)
        if (hello.protocolVersion != Protocol.VERSION) {
            Log.w(TAG, "Session $id: unsupported protocol version ${hello.protocolVersion}")
            throw Ended(EndReason.INCOMPATIBLE_VERSION)
        }
        val helloPayload = first.copyPayload()
        val macIdentity = SessionCrypto.decodePublicKey(hello.identityKey)
        val macEphemeral = SessionCrypto.decodePublicKey(hello.ephemeralKey)
        listener.onSenderName(id, hello.deviceName)

        val identity = pairing.identity()
        val ephemeral = SessionCrypto.generateKeyPair()
        val tvIdentityKey = SessionCrypto.encodePublicKey(identity.public)
        val serverHello = ServerHello.encode(
            knowsSender = pairing.isPaired(hello.identityKey),
            identityKey = tvIdentityKey,
            ephemeralKey = SessionCrypto.encodePublicKey(ephemeral.public),
            name = tvName()
        )
        writer.write(PacketType.SERVER_HELLO, serverHello)

        while (true) {
            val packet = reader.next() ?: throw Ended(EndReason.CONNECTION_LOST)
            when (packet.type) {
                PacketType.PING -> Unit
                PacketType.PAIR_START -> pair(reader, writer, hello, tvIdentityKey)
                PacketType.SESSION_START -> {
                    if (!pairing.isPaired(hello.identityKey)) {
                        writer.write(PacketType.REJECT, byteArrayOf(RejectReason.NOT_PAIRED.code.toByte()))
                        throw Ended(EndReason.NOT_PAIRED)
                    }
                    break
                }
                else -> throw ProtocolException("Unexpected ${packet.type} during the handshake")
            }
        }

        val (macToTv, tvToMac) = SessionCrypto.sessionKeysForTv(
            tvIdentity = identity.private,
            tvEphemeral = ephemeral.private,
            macIdentity = macIdentity,
            macEphemeral = macEphemeral,
            helloPayload = helloPayload,
            serverHelloPayload = serverHello
        )
        reader.cipher = RecordCipher(macToTv)
        writer.cipher = RecordCipher(tvToMac)
        writer.write(PacketType.READY)
        Log.i(TAG, "Session $id: encrypted session established")
    }

    /** Numeric-comparison pairing; returns when both users confirmed, otherwise throws [Ended]. */
    private fun pair(reader: PacketReader, writer: PacketWriter, hello: Hello, tvIdentityKey: ByteArray) {
        val tvNonce = SessionCrypto.randomBytes(SessionCrypto.NONCE_LENGTH)
        writer.write(PacketType.PAIR_COMMIT, SessionCrypto.commitment(tvNonce, tvIdentityKey, hello.identityKey))

        var macNonce: ByteArray? = null
        while (macNonce == null) {
            val packet = reader.next() ?: throw Ended(EndReason.CONNECTION_LOST)
            when (packet.type) {
                PacketType.PING -> Unit
                PacketType.PAIR_NONCE -> {
                    if (packet.length != SessionCrypto.NONCE_LENGTH) throw ProtocolException("Malformed pairing nonce")
                    macNonce = packet.copyPayload()
                }
                else -> throw ProtocolException("Unexpected ${packet.type} while pairing")
            }
        }
        writer.write(PacketType.PAIR_NONCE, tvNonce)

        val code = SessionCrypto.pairingCode(hello.identityKey, tvIdentityKey, macNonce, tvNonce)
        pairingDecision.set(null)
        listener.onPairingRequest(id, hello.deviceName, code)

        val deadline = System.currentTimeMillis() + Protocol.PAIRING_TIMEOUT_MS
        var localSent = false
        var remote: Boolean? = null
        while (true) {
            val local = pairingDecision.get()
            if (local != null && !localSent) {
                writer.write(PacketType.PAIR_CONFIRM, byteArrayOf(if (local) 1 else 0))
                localSent = true
                if (!local) {
                    writer.write(PacketType.REJECT, byteArrayOf(RejectReason.PAIRING_DECLINED.code.toByte()))
                    throw Ended(EndReason.PAIRING_DECLINED)
                }
            }
            if (remote == false) throw Ended(EndReason.PAIRING_CANCELLED)
            if (local == true && remote == true) break
            if (System.currentTimeMillis() > deadline) {
                writer.write(PacketType.REJECT, byteArrayOf(RejectReason.PAIRING_TIMED_OUT.code.toByte()))
                throw Ended(EndReason.PAIRING_TIMED_OUT)
            }
            // The Mac pings every second, so this returns often enough to notice the local decision.
            val packet = reader.next() ?: throw Ended(EndReason.CONNECTION_LOST)
            when (packet.type) {
                PacketType.PING -> Unit
                PacketType.PAIR_CONFIRM -> remote = packet.length >= 1 && packet.payload[0].toInt() == 1
                else -> throw ProtocolException("Unexpected ${packet.type} while pairing")
            }
        }
        pairing.pair(hello.deviceName, hello.identityKey)
        listener.onPaired(id)
        Log.i(TAG, "Session $id: paired with ${hello.deviceName}")
    }

    // endregion

    private fun stream(reader: PacketReader): EndReason {
        val audio = AudioPlayer()
        var audioStarted = false
        var frames = 0
        var bytes = 0L
        var statsStart = System.nanoTime()
        try {
            while (true) {
                val packet = reader.next() ?: return EndReason.CONNECTION_LOST
                bytes += Protocol.HEADER_SIZE + packet.length
                when (packet.type) {
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
                    else -> Unit // PING and types added by newer senders
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
        } finally {
            audio.stop()
        }
    }

    private companion object {
        const val TAG = "StreamSession"
        const val STATS_INTERVAL_NS = 1_000_000_000L
    }
}
