package app.beamly.tv.net

import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.ProtocolException
import java.nio.ByteBuffer
import kotlin.random.Random
import org.junit.Test

/**
 * Malformed input from the network must end a session with an I/O or protocol error, never crash the receiver
 * with another exception type (index out of bounds, negative array size, out of memory, ...).
 */
class FuzzTest {
    private val random = Random(20261124)

    private inline fun expectOnlyIoErrors(block: () -> Unit) {
        try {
            block()
        } catch (_: ProtocolException) {
        } catch (_: IOException) {
        }
    }

    @Test
    fun randomBytesIntoPlaintextReader() {
        repeat(5_000) {
            val bytes = random.nextBytes(random.nextInt(0, 64))
            expectOnlyIoErrors {
                val reader = PacketReader(ByteArrayInputStream(bytes), initialCapacity = 16)
                while (reader.next() != null) Unit
            }
        }
    }

    @Test
    fun randomRecordsIntoEncryptedReader() {
        repeat(2_000) {
            // A plausible length prefix followed by random ciphertext: must fail authentication, not crash.
            val body = random.nextBytes(random.nextInt(0, 80))
            val bytes = ByteBuffer.allocate(4 + body.size).putInt(random.nextInt(-4, 120)).put(body).array()
            expectOnlyIoErrors {
                val reader = PacketReader(ByteArrayInputStream(bytes), initialCapacity = 16)
                reader.cipher = RecordCipher(ByteArray(32))
                while (reader.next() != null) Unit
            }
        }
    }

    @Test
    fun randomPayloadsIntoParsers() {
        repeat(5_000) {
            val payload = random.nextBytes(random.nextInt(0, 200))
            val length = random.nextInt(0, payload.size + 1)
            expectOnlyIoErrors { Hello.parse(payload, length) }
            expectOnlyIoErrors { VideoConfig.parse(payload, length) }
            expectOnlyIoErrors { VolumeState.parse(payload, length) }
            if (length == SessionCrypto.PUBLIC_KEY_LENGTH) expectOnlyIoErrors { SessionCrypto.decodePublicKey(payload.copyOf(length)) }
        }
    }

    @Test
    fun versionTwoHelloWithTruncatedKeys() {
        repeat(200) {
            val payload = byteArrayOf(0, Protocol.VERSION.toByte()) + random.nextBytes(random.nextInt(0, 147))
            expectOnlyIoErrors { Hello.parse(payload, payload.size) }
        }
    }
}
