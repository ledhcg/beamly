package app.beamly.tv.net

import android.util.Log
import app.beamly.tv.media.VideoDecoder
import java.io.BufferedInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Accepts TCP connections from senders. There is one session at a time; a new connection always
 * replaces the current one (even if the current one is stuck or its network dropped silently).
 */
class StreamServer(
    private val port: Int,
    private val decoder: VideoDecoder,
    private val pairing: PairingStore,
    private val tvName: () -> String,
    private val listener: Listener
) {
    interface Listener : StreamSession.Listener {
        fun onListening()
        fun onServerError(error: IOException)
        fun onSessionStarted(sessionId: Long, remoteAddress: String)
        fun onSessionEnded(sessionId: Long, reason: EndReason)
    }

    private val ids = AtomicLong()
    private val lock = Any()
    private var scope: CoroutineScope? = null

    @Volatile private var serverSocket: ServerSocket? = null
    private var current: Pair<StreamSession, Job>? = null
    private val promotion = Mutex()

    val isRunning: Boolean get() = synchronized(lock) { scope != null }

    fun start() {
        synchronized(lock) {
            if (scope != null) return
            val s = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            scope = s
            s.launch { acceptLoop(s) }
        }
    }

    fun stop() {
        val (s, session) = synchronized(lock) {
            val pair = scope to current
            scope = null
            current = null
            pair
        }
        runCatching { serverSocket?.close() }
        serverSocket = null
        session?.first?.close()
        s?.cancel()
    }

    /** Forwards the TV user's pairing decision to the session that asked for it. */
    fun respondToPairing(sessionId: Long, accepted: Boolean) {
        val session = synchronized(lock) { current?.first }
        if (session?.id == sessionId) session.respondToPairing(accepted)
    }

    private suspend fun acceptLoop(scope: CoroutineScope) {
        val server = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(port))
            }
        } catch (e: IOException) {
            Log.e(TAG, "Cannot listen on port $port", e)
            listener.onServerError(e)
            return
        }
        serverSocket = server
        Log.i(TAG, "Listening on port $port")
        listener.onListening()
        try {
            while (scope.isActive) {
                val socket = server.accept()
                scope.launch { handshake(scope, socket) }
            }
        } catch (e: IOException) {
            if (scope.isActive) {
                Log.e(TAG, "Accept failed", e)
                listener.onServerError(e)
            }
        } finally {
            runCatching { server.close() }
        }
    }

    /**
     * Promotes a connection only after the sender has sent data (HELLO is sent immediately).
     * Network.framework may open parallel connections to several of the TV's addresses (Happy Eyeballs)
     * and abandon the losers; those never send anything and must not replace the running session.
     */
    private suspend fun handshake(scope: CoroutineScope, socket: Socket) {
        val input = try {
            socket.tcpNoDelay = true
            socket.receiveBufferSize = 1 shl 20
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            BufferedInputStream(socket.getInputStream(), 64 * 1024).also {
                it.mark(1)
                if (it.read() < 0) throw IOException("closed before handshake")
                it.reset()
            }
        } catch (e: IOException) {
            Log.i(TAG, "Ignoring connection from ${socket.inetAddress?.hostAddress}: $e")
            runCatching { socket.close() }
            return
        }
        promotion.withLock { startSession(scope, socket, input) }
    }

    private suspend fun startSession(scope: CoroutineScope, socket: Socket, input: java.io.InputStream) {
        // Close the previous session and wait for its cleanup (decoder and audio are shared) before starting.
        val previous = synchronized(lock) { current }
        previous?.let { (session, job) ->
            session.close()
            if (withTimeoutOrNull(PREVIOUS_SESSION_TIMEOUT_MS) { job.join() } == null) {
                Log.w(TAG, "Session ${session.id} did not stop in time")
            }
        }
        val session = StreamSession(ids.incrementAndGet(), socket, input, decoder, pairing, tvName, listener)
        Log.i(TAG, "Session ${session.id} from ${session.remoteAddress}")
        listener.onSessionStarted(session.id, session.remoteAddress)
        val job = scope.launch {
            val reason = session.run()
            Log.i(TAG, "Session ${session.id} ended: $reason")
            listener.onSessionEnded(session.id, reason)
        }
        synchronized(lock) {
            if (this.scope === scope) current = session to job else session.close()
        }
    }

    private companion object {
        const val TAG = "StreamServer"
        const val PREVIOUS_SESSION_TIMEOUT_MS = 3_000L
        const val HANDSHAKE_TIMEOUT_MS = 3_000
    }
}
