package app.beamly.tv.net

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.net.ProtocolException
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class ProtocolTest {

    // region Shared fixtures (protocol/test-vectors/packets.json), also used by the macOS sender's tests

    private val vectors: JSONObject by lazy {
        // Gradle runs unit tests with the module directory (android/app) as the working directory.
        JSONObject(File("../../protocol/test-vectors/packets.json").readText())
    }

    private fun vector(name: String): JSONObject {
        val packets = vectors.getJSONArray("packets")
        for (i in 0 until packets.length()) {
            val packet = packets.getJSONObject(i)
            if (packet.getString("name") == name) return packet
        }
        throw AssertionError("Missing test vector $name")
    }

    private fun hex(value: String): ByteArray = ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun decode(name: String): Packet = PacketReader(ByteArrayInputStream(hex(vector(name).getString("encodedHex")))).next()!!

    @Test
    fun protocolVersionMatchesFixtures() {
        assertEquals(vectors.getInt("protocolVersion"), Protocol.VERSION)
    }

    @Test
    fun decodesEverySharedPacket() {
        val packets = vectors.getJSONArray("packets")
        for (i in 0 until packets.length()) {
            val expected = packets.getJSONObject(i)
            val name = expected.getString("name")
            val packet = decode(name)
            assertEquals(name, expected.getInt("type"), packet.type?.code)
            assertEquals(name, expected.getLong("ptsMicros"), packet.ptsUs)
            assertArrayEquals(name, hex(expected.getString("payloadHex")), packet.copyPayload())
        }
    }

    @Test
    fun parsesSharedHello() {
        val expected = vector("hello").getJSONObject("expected")
        val packet = decode("hello")
        val hello = Hello.parse(packet.payload, packet.length)
        assertEquals(expected.getInt("protocolVersion"), hello.protocolVersion)
        assertArrayEquals(hex(expected.getString("deviceIdHex")), hello.deviceId)
        assertArrayEquals(hex(expected.getString("identityKeyHex")), hello.identityKey)
        assertArrayEquals(hex(expected.getString("ephemeralKeyHex")), hello.ephemeralKey)
        assertEquals(expected.getString("deviceName"), hello.deviceName)
    }

    @Test
    fun helloFromAnOlderVersionOnlyReportsTheVersion() {
        val v1 = byteArrayOf(0, 1) + "Old Mac".toByteArray()
        val hello = Hello.parse(v1, v1.size)
        assertEquals(1, hello.protocolVersion)
        assertEquals("", hello.deviceName)
    }

    @Test
    fun encodesSharedServerHello() {
        val vector = vector("server-hello")
        val expected = vector.getJSONObject("expected")
        val payload = ServerHello.encode(
            knowsSender = expected.getBoolean("knowsSender"),
            identityKey = hex(expected.getString("identityKeyHex")),
            ephemeralKey = hex(expected.getString("ephemeralKeyHex")),
            name = expected.getString("name")
        )
        assertArrayEquals(hex(vector.getString("payloadHex")), payload)
    }

    @Test
    fun parsesSharedVolumes() {
        for (name in listOf("volume", "volume-muted")) {
            val expected = vector(name).getJSONObject("expected")
            val packet = decode(name)
            assertEquals(
                name,
                VolumeState(
                    expected.getDouble("volume").toFloat(),
                    expected.getDouble("gain").toFloat(),
                    expected.getBoolean("muted")
                ),
                VolumeState.parse(packet.payload, packet.length)
            )
        }
    }

    @Test
    fun parsesSharedConfig() {
        val expected = vector("config").getJSONObject("expected")
        val packet = decode("config")
        val config = VideoConfig.parse(packet.payload, packet.length)
        assertEquals(expected.getInt("width"), config.width)
        assertEquals(expected.getInt("height"), config.height)
        assertArrayEquals(hex(expected.getString("spsHex")), config.sps)
        assertArrayEquals(hex(expected.getString("ppsHex")), config.pps)
    }

    @Test(expected = ProtocolException::class)
    fun rejectsTruncatedHello() {
        Hello.parse(byteArrayOf(0), 1)
    }

    // endregion

    private fun packet(type: Int, pts: Long, payload: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        DataOutputStream(out).apply {
            writeInt(payload.size)
            writeByte(type)
            writeLong(pts)
            write(payload)
        }
        return out.toByteArray()
    }

    private fun config(w: Int, h: Int, sps: ByteArray, pps: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        DataOutputStream(out).apply {
            writeShort(w)
            writeShort(h)
            writeShort(sps.size)
            write(sps)
            writeShort(pps.size)
            write(pps)
        }
        return out.toByteArray()
    }

    @Test
    fun readsSequentialPacketsAndEndsCleanly() {
        val stream = packet(1, 1_000, byteArrayOf(1, 2, 3)) + packet(5, 0, byteArrayOf()) + packet(3, 42, ByteArray(8) { it.toByte() })
        val reader = PacketReader(ByteArrayInputStream(stream), initialCapacity = 2)

        val first = reader.next()!!
        assertEquals(PacketType.KEY_FRAME, first.type)
        assertEquals(1_000L, first.ptsUs)
        assertArrayEquals(byteArrayOf(1, 2, 3), first.copyPayload())

        val ping = reader.next()!!
        assertEquals(PacketType.PING, ping.type)
        assertEquals(0, ping.length)

        val audio = reader.next()!!
        assertEquals(PacketType.AUDIO, audio.type)
        assertEquals(8, audio.length) // the buffer grew from 2 bytes

        assertNull(reader.next())
    }

    @Test
    fun reusesBufferBetweenPackets() {
        val reader = PacketReader(ByteArrayInputStream(packet(2, 0, ByteArray(10)) + packet(2, 0, ByteArray(5))))
        val a = reader.next()!!
        val b = reader.next()!!
        assertSame(a.payload, b.payload)
    }

    @Test
    fun unknownTypeIsNullNotError() {
        val reader = PacketReader(ByteArrayInputStream(packet(99, 0, byteArrayOf(7))))
        assertNull(reader.next()!!.type)
    }

    @Test(expected = ProtocolException::class)
    fun rejectsNegativeLength() {
        val bad = byteArrayOf(0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 2) + ByteArray(8)
        PacketReader(ByteArrayInputStream(bad)).next()
    }

    @Test(expected = EOFException::class)
    fun truncatedPayloadThrows() {
        val p = packet(2, 0, ByteArray(10))
        PacketReader(ByteArrayInputStream(p.copyOf(p.size - 3))).next()
    }

    @Test
    fun parsesVolumePacket() {
        val out = ByteArrayOutputStream()
        DataOutputStream(out).apply {
            writeFloat(0.5f)
            writeFloat(0.12f)
            writeByte(0)
        }
        val bytes = out.toByteArray()
        assertEquals(VolumeState(0.5f, 0.12f, false), VolumeState.parse(bytes, bytes.size))

        val muted = bytes.copyOf().also { it[8] = 1 }
        assertEquals(VolumeState(0.5f, 0f, true), VolumeState.parse(muted, muted.size)) // mute => gain 0

        val clamped = ByteArrayOutputStream().also {
            DataOutputStream(it).apply {
                writeFloat(3f)
                writeFloat(-1f)
                writeByte(0)
            }
        }.toByteArray()
        assertEquals(VolumeState(1f, 0f, false), VolumeState.parse(clamped, clamped.size))
    }

    @Test(expected = ProtocolException::class)
    fun rejectsTruncatedVolume() {
        VolumeState.parse(ByteArray(5), 5)
    }

    @Test
    fun parsesVideoConfig() {
        val sps = byteArrayOf(0x67, 0x64, 0x00, 0x28)
        val pps = byteArrayOf(0x68, 0xee.toByte())
        val cfg = VideoConfig.parse(config(1920, 1248, sps, pps))
        assertEquals(1920, cfg.width)
        assertEquals(1248, cfg.height)
        assertArrayEquals(sps, cfg.sps)
        assertArrayEquals(pps, cfg.pps)
        assertEquals(cfg, VideoConfig.parse(config(1920, 1248, sps, pps)))
        assertNotEquals(cfg, VideoConfig.parse(config(1280, 720, sps, pps)))
    }

    @Test(expected = ProtocolException::class)
    fun rejectsTruncatedConfig() {
        val full = config(1920, 1080, byteArrayOf(1, 2, 3), byteArrayOf(4))
        VideoConfig.parse(full, full.size - 2)
    }
}
