package app.beamly.tv.media

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import app.beamly.tv.net.Protocol
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Plays PCM s16le 48 kHz stereo on its own thread so the network thread never blocks.
 * When more than [MAX_QUEUED_MS] is queued (clock drift between sender and TV, network jitter),
 * the oldest audio is dropped to keep latency low.
 */
class AudioPlayer {

    private val queue = ArrayBlockingQueue<ByteArray>(256)
    private val queuedBytes = AtomicInteger()

    @Volatile private var running = false

    @Volatile private var gain = 1f
    private var track: AudioTrack? = null
    private var thread: Thread? = null

    fun start() {
        if (running) return
        val minBuffer = AudioTrack.getMinBufferSize(
            Protocol.AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(Protocol.AUDIO_SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(minBuffer, 40 * BYTES_PER_MS))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        t.setVolume(gain)
        t.play()
        track = t
        running = true
        thread = Thread(::playLoop, "beamly-audio").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    /** Playback gain (0..1, linear) mirroring the sender's volume. */
    fun setGain(value: Float) {
        gain = value.coerceIn(0f, 1f)
        track?.let { runCatching { it.setVolume(gain) } }
    }

    /** Called from the network thread; never blocks. */
    fun enqueue(pcm: ByteArray) {
        if (!running) return
        if (queue.offer(pcm)) queuedBytes.addAndGet(pcm.size)
        if (queuedBytes.get() > MAX_QUEUED_MS * BYTES_PER_MS) {
            while (queuedBytes.get() > TARGET_QUEUED_MS * BYTES_PER_MS) {
                val dropped = queue.poll() ?: break
                queuedBytes.addAndGet(-dropped.size)
            }
        }
    }

    private fun playLoop() {
        try {
            while (running) {
                val pcm = queue.poll(100, TimeUnit.MILLISECONDS) ?: continue
                queuedBytes.addAndGet(-pcm.size)
                if (!running) break
                track?.write(pcm, 0, pcm.size)
            }
        } catch (_: InterruptedException) {
        } catch (e: Exception) {
            Log.w(TAG, "Audio playback stopped", e)
        }
    }

    fun stop() {
        if (!running && track == null) return
        running = false
        // pause() first to unblock a thread stuck in write(); releasing while write() blocks can hang.
        track?.let {
            runCatching {
                it.pause()
                it.flush()
            }
        }
        thread?.let {
            it.interrupt()
            runCatching { it.join(500) }
        }
        track?.let { runCatching { it.release() } }
        track = null
        thread = null
        queue.clear()
        queuedBytes.set(0)
    }

    private companion object {
        const val TAG = "AudioPlayer"
        const val BYTES_PER_MS = Protocol.AUDIO_SAMPLE_RATE * Protocol.AUDIO_BYTES_PER_FRAME / 1000
        const val MAX_QUEUED_MS = 120
        const val TARGET_QUEUED_MS = 40
    }
}
