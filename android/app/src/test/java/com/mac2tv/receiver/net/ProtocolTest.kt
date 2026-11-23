package com.mac2tv.receiver.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.net.ProtocolException

class ProtocolTest {

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
            writeShort(w); writeShort(h)
            writeShort(sps.size); write(sps)
            writeShort(pps.size); write(pps)
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
        assertEquals(8, audio.length)  // buffer đã tự nới rộng từ 2 byte

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
        DataOutputStream(out).apply { writeFloat(0.5f); writeFloat(0.12f); writeByte(0) }
        val bytes = out.toByteArray()
        assertEquals(VolumeState(0.5f, 0.12f, false), VolumeState.parse(bytes, bytes.size))

        val muted = bytes.copyOf().also { it[8] = 1 }
        assertEquals(VolumeState(0.5f, 0f, true), VolumeState.parse(muted, muted.size))   // mute => gain 0

        val clamped = ByteArrayOutputStream().also { DataOutputStream(it).apply { writeFloat(3f); writeFloat(-1f); writeByte(0) } }.toByteArray()
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
