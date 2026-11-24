package app.beamly.tv.net

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.ProtocolException
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Checks protocol version 2 cryptography against `protocol/test-vectors/crypto.json`, generated with CryptoKit and
 * also verified by the macOS sender's tests.
 */
class CryptoTest {
    private val vectors = JSONObject(File("../../protocol/test-vectors/crypto.json").readText())
    private val keys = vectors.getJSONObject("keys")
    private val handshake = vectors.getJSONObject("handshake")
    private val pairing = vectors.getJSONObject("pairing")

    private fun hex(value: String): ByteArray = ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun key(name: String) = hex(keys.getString(name))

    @Test
    fun versionMatches() {
        assertEquals(vectors.getInt("protocolVersion"), Protocol.VERSION)
    }

    @Test
    fun publicKeysRoundTrip() {
        val encoded = key("macIdentityPublicHex")
        assertArrayEquals(encoded, SessionCrypto.encodePublicKey(SessionCrypto.decodePublicKey(encoded)))
        val pair = SessionCrypto.keyPair(key("tvIdentityPrivateHex"), key("tvIdentityPublicHex"))
        assertArrayEquals(key("tvIdentityPrivateHex"), SessionCrypto.encodePrivateKey(pair.private))
    }

    @Test(expected = ProtocolException::class)
    fun rejectsPointsOffTheCurve() {
        val bad = key("macIdentityPublicHex").also { it[64] = (it[64].toInt() xor 1).toByte() }
        SessionCrypto.decodePublicKey(bad)
    }

    @Test
    fun sessionKeysFromTheTvSide() {
        val (macToTv, tvToMac) = SessionCrypto.sessionKeysForTv(
            tvIdentity = SessionCrypto.decodePrivateKey(key("tvIdentityPrivateHex")),
            tvEphemeral = SessionCrypto.decodePrivateKey(key("tvEphemeralPrivateHex")),
            macIdentity = SessionCrypto.decodePublicKey(key("macIdentityPublicHex")),
            macEphemeral = SessionCrypto.decodePublicKey(key("macEphemeralPublicHex")),
            helloPayload = hex(handshake.getString("helloPayloadHex")),
            serverHelloPayload = hex(handshake.getString("serverHelloPayloadHex"))
        )
        assertArrayEquals(hex(handshake.getString("macToTvKeyHex")), macToTv)
        assertArrayEquals(hex(handshake.getString("tvToMacKeyHex")), tvToMac)
    }

    @Test
    fun pairingCommitmentAndCode() {
        val macKey = key("macIdentityPublicHex")
        val tvKey = key("tvIdentityPublicHex")
        val macNonce = hex(pairing.getString("macNonceHex"))
        val tvNonce = hex(pairing.getString("tvNonceHex"))
        assertArrayEquals(hex(pairing.getString("commitmentHex")), SessionCrypto.commitment(tvNonce, tvKey, macKey))
        assertEquals(pairing.getString("code"), SessionCrypto.pairingCode(macKey, tvKey, macNonce, tvNonce))
    }

    @Test
    fun readsTheMacsEncryptedRecords() {
        // The Mac → TV records from the fixture, read through PacketReader exactly as a session does.
        val records = vectors.getJSONArray("records")
        val stream = ByteArrayOutputStream()
        val expected = (0 until records.length()).map { records.getJSONObject(it) }.filter { it.getString("direction") == "macToTv" }
        expected.forEach { stream.write(hex(it.getString("recordHex"))) }
        val reader = PacketReader(ByteArrayInputStream(stream.toByteArray()))
        reader.cipher = RecordCipher(hex(handshake.getString("macToTvKeyHex")))
        for (record in expected) {
            val packet = reader.next()
            assertNotNull(packet)
            packet!!
            assertEquals(record.getInt("type"), packet.type?.code)
            assertEquals(record.getLong("ptsMicros"), packet.ptsUs)
            assertArrayEquals(hex(record.getString("payloadHex")), packet.copyPayload())
        }
    }

    @Test
    fun writesTheTvsReadyRecord() {
        val record = (0 until vectors.getJSONArray("records").length())
            .map { vectors.getJSONArray("records").getJSONObject(it) }
            .single { it.getString("direction") == "tvToMac" }
        val out = ByteArrayOutputStream()
        PacketWriter(out).apply { cipher = RecordCipher(hex(handshake.getString("tvToMacKeyHex"))) }.write(PacketType.READY)
        assertArrayEquals(hex(record.getString("recordHex")), out.toByteArray())
    }

    @Test(expected = ProtocolException::class)
    fun rejectsTamperedRecords() {
        val sealer = RecordCipher(hex(handshake.getString("macToTvKeyHex")))
        val record = sealer.seal(PacketType.AUDIO.code, 0, byteArrayOf(1, 2, 3))
        record[6] = (record[6].toInt() xor 1).toByte()
        val reader = PacketReader(ByteArrayInputStream(record))
        reader.cipher = RecordCipher(hex(handshake.getString("macToTvKeyHex")))
        reader.next()
    }

    @Test(expected = ProtocolException::class)
    fun rejectsReplayedRecords() {
        val key = hex(handshake.getString("macToTvKeyHex"))
        val first = RecordCipher(key).seal(PacketType.PING.code, 0, ByteArray(0))
        val reader = PacketReader(ByteArrayInputStream(first + first))
        reader.cipher = RecordCipher(key)
        reader.next()
        reader.next() // same nonce counter value cannot authenticate twice
    }
}
