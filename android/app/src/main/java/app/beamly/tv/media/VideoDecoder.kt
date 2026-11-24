package app.beamly.tv.media

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import app.beamly.tv.net.VideoConfig
import java.nio.ByteBuffer

/**
 * Decodes H.264 (Annex-B) in hardware and renders frames to a [Surface] immediately.
 *
 * The surface (from the UI) and the configuration (from the sender) can arrive in any order and change at any time;
 * on every change the decoder is recreated and waits for the next key frame (sent at least every 2 seconds).
 * Thread-safe.
 */
class VideoDecoder(private val onFrameRendered: () -> Unit) {

    private val lock = Any()
    private var surface: Surface? = null
    private var config: VideoConfig? = null
    private var codec: MediaCodec? = null
    private var waitingForKeyFrame = true
    private val info = MediaCodec.BufferInfo()

    fun setSurface(newSurface: Surface?) = synchronized(lock) {
        if (newSurface === surface) return
        releaseCodec()
        surface = newSurface
    }

    fun configure(newConfig: VideoConfig) = synchronized(lock) {
        if (newConfig == config && codec != null) return
        releaseCodec()
        config = newConfig
    }

    /** Releases the decoder and forgets the configuration (between sessions). */
    fun reset() = synchronized(lock) {
        releaseCodec()
        config = null
    }

    /** @return `true` if the frame was queued to the decoder, `false` if it was dropped. */
    fun decode(data: ByteArray, length: Int, ptsUs: Long, keyFrame: Boolean): Boolean = synchronized(lock) {
        if (waitingForKeyFrame && !keyFrame) return false
        val c = codec ?: createCodec() ?: return false
        try {
            val index = dequeueInput(c)
            if (index < 0) {
                Log.w(TAG, "Decoder busy, dropping frame")
                waitingForKeyFrame = true
                return false
            }
            val input = c.getInputBuffer(index) ?: return false
            if (input.capacity() < length) {
                Log.w(TAG, "Frame too large ($length > ${input.capacity()}), dropping")
                c.queueInputBuffer(index, 0, 0, ptsUs, 0)
                waitingForKeyFrame = true
                return false
            }
            input.clear()
            input.put(data, 0, length)
            c.queueInputBuffer(index, 0, length, ptsUs, if (keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            waitingForKeyFrame = false
            drain(c)
            true
        } catch (e: IllegalStateException) {
            // MediaCodec.CodecException is an IllegalStateException too
            Log.e(TAG, "Decoder error, recreating", e)
            releaseCodec()
            false
        }
    }

    private fun dequeueInput(c: MediaCodec): Int {
        val deadline = System.nanoTime() + INPUT_WAIT_NS
        while (true) {
            val index = c.dequeueInputBuffer(10_000)
            if (index >= 0) return index
            drain(c)
            if (System.nanoTime() > deadline) return -1
        }
    }

    private fun drain(c: MediaCodec) {
        while (true) {
            val index = c.dequeueOutputBuffer(info, 0)
            when {
                index >= 0 -> {
                    // Render now; never use the sender's PTS as a display time.
                    c.releaseOutputBuffer(index, System.nanoTime())
                    onFrameRendered()
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                else -> Unit // INFO_OUTPUT_FORMAT_CHANGED, ...
            }
        }
    }

    private fun createCodec(): MediaCodec? {
        val s = surface?.takeIf { it.isValid } ?: return null
        val cfg = config ?: return null
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, cfg.width, cfg.height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(START_CODE + cfg.sps))
            setByteBuffer("csd-1", ByteBuffer.wrap(START_CODE + cfg.pps))
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        var created: MediaCodec? = null
        return try {
            created = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            created.configure(format, s, null, 0)
            created.start()
            Log.i(TAG, "Decoder started: $cfg (${created.name})")
            waitingForKeyFrame = true
            codec = created
            created
        } catch (e: Exception) {
            Log.e(TAG, "Cannot create decoder for $cfg", e)
            runCatching { created?.release() }
            null
        }
    }

    private fun releaseCodec() {
        // release() directly: stop() hangs on some TV SoCs.
        codec?.let { runCatching { it.release() } }
        codec = null
        waitingForKeyFrame = true
    }

    private companion object {
        const val TAG = "VideoDecoder"
        const val INPUT_WAIT_NS = 500_000_000L
        val START_CODE = byteArrayOf(0, 0, 0, 1)
    }
}
