package com.androp.network

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.security.MessageDigest
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** One socket shared by the foreground app, share target, and edge service. */
object AndropConnection {
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val observers = mutableSetOf<(Boolean, String) -> Unit>()
    private const val CHUNKS_IN_FLIGHT = 8 // 2 MiB of payload; stay below OkHttp's 16 MiB outgoing queue.
    private class UploadSignals {
        val ready = CompletableDeferred<Unit>()
        val acknowledgements = Channel<Long>(CHUNKS_IN_FLIGHT)
        fun fail(error: Throwable) { ready.completeExceptionally(error); acknowledgements.close(error) }
    }
    private val uploads = ConcurrentHashMap<String, UploadSignals>()
    private val waiting = mutableMapOf<String, CompletableDeferred<String>>()
    private var discovery: MacDiscovery? = null
    private var context: Context? = null
    private var users = 0
    private var reconnect: Job? = null
    private var discovered: Triple<String, Int, String>? = null
    private var endpoint: Pair<String, Int>? = null
    var message = "Pair with your Mac to begin"
        private set
    @Volatile var isConnected = false
        private set
    val client = StreamClient({ connected, status, shouldRetry -> main.post {
        isConnected = connected
        message = status
        observers.toList().forEach { it(connected, status) }
        if (!connected) {
            if (users > 0) discovery?.start()
            waiting.values.forEach { it.completeExceptionally(IllegalStateException(status)) }
            waiting.clear()
            uploads.values.forEach { it.fail(IllegalStateException(status)) }
            if (shouldRetry) scheduleReconnect()
        } else { reconnect?.cancel(); discovery?.stop() }
    } }, { id, ok, status -> main.post {
        waiting[id]?.let { if (ok) it.complete(status) else it.completeExceptionally(IllegalStateException(status)) }
        if (!ok) uploads[id]?.fail(IllegalStateException(status))
    } }, { id, type, received ->
        // Coroutines' deferred/channel primitives are thread-safe. ACKs must not queue behind UI work.
        uploads[id]?.let { signals ->
            if (type == "TRANSFER_READY") signals.ready.complete(Unit)
            else if (signals.acknowledgements.trySend(received).isFailure) signals.fail(IllegalStateException("Unexpected transfer acknowledgement"))
        }
    })

    fun acquire(context: Context) {
        users++
        if (users > 1) { updateDiscovery(); return }
        this.context = context.applicationContext
        val prefs = context.getSharedPreferences("androp", Context.MODE_PRIVATE)
        updateDiscovery()
        val host = prefs.getString("host", "").orEmpty()
        if (host.isNotBlank() && prefs.getString("code", "").orEmpty().length == 6) connect(host, prefs.getInt("port", 8989))
    }

    /**
     * Bonjour discovery holds a Wi-Fi multicast lock, which keeps the radio from dozing. Screens
     * report when they are hidden, so discovery runs only while something visible (or the edge
     * overlay) needs it. Hiding never drops the connection or an upload in progress.
     */
    private var hiddenUsers = 0

    fun hidden(isHidden: Boolean) {
        hiddenUsers = (hiddenUsers + if (isHidden) 1 else -1).coerceIn(0, users)
        updateDiscovery()
    }

    private fun updateDiscovery() {
        val app = context ?: return
        if (users <= hiddenUsers) {
            discovery?.stop()
            discovery = null
            return
        }
        if (discovery != null) return
        val prefs = app.getSharedPreferences("androp", Context.MODE_PRIVATE)
        discovery = MacDiscovery(app) { host, port, name ->
            val savedHost = prefs.getString("host", "").orEmpty()
            val savedName = prefs.getString("serviceName", null)
            val manual = prefs.getBoolean("manualHost", true)
            if (savedHost.isEmpty() || (!manual && (savedName == null || savedName == name))) {
                discovered = Triple(host, port, name)
                if (!isConnected && prefs.getString("code", "").isNullOrBlank()) {
                    message = "Mac found · enter its pairing code"
                    observers.toList().forEach { it(false, message) }
                }
            }
            // Discovery must never replace an explicitly paired IP/hostname or choose another Mac.
            val allowed = if (manual) savedHost == host && prefs.getInt("port", 8989) == port else savedName == name
            if (!isConnected && allowed && endpoint != (host to port) && !prefs.getString("code", "").isNullOrBlank()) connect(host, port)
        }.also { it.start() }
    }

    fun observe(callback: (Boolean, String) -> Unit) { observers.add(callback); callback(isConnected, message) }
    fun removeObserver(callback: (Boolean, String) -> Unit) { observers.remove(callback) }
    fun release() {
        users = (users - 1).coerceAtLeast(0)
        hiddenUsers = hiddenUsers.coerceAtMost(users)
        if (users != 0) { updateDiscovery(); return }
        reconnect?.cancel()
        discovery?.stop()
        discovery = null
        client.disconnect()
        isConnected = false
        waiting.values.forEach { it.cancel() }
        waiting.clear()
        uploads.values.forEach { it.fail(CancellationException("Connection closed")) }
        uploads.clear()
    }

    fun pair(host: String, code: String) {
        if (host.isNotBlank()) {
            pair(PairingEndpoint.manual(host), code)
            return
        }
        val (address, port, name) = discovered ?: run {
            val prefs = requireNotNull(context).getSharedPreferences("androp", Context.MODE_PRIVATE)
            val savedName = prefs.getString("serviceName", null)
            val selected = endpoint
            require(!prefs.getBoolean("manualHost", true) && savedName != null && selected != null) {
                "No Mac found yet. Scan its pairing QR or enter its local IP address."
            }
            Triple(selected.first, selected.second, savedName)
        }
        pair(PairingEndpoint(address, port), code, name)
    }

    internal fun pair(endpoint: PairingEndpoint, code: String, serviceName: String? = null) {
        require(PairingEndpoint.validCode(code)) { "Enter the six-digit code from Zera" }
        reconnect?.cancel()
        reconnect = null
        context!!.getSharedPreferences("androp", Context.MODE_PRIVATE).edit()
            .putString("host", endpoint.host).putString("code", code).putInt("port", endpoint.port)
            .putBoolean("manualHost", serviceName == null)
            .putString("serviceName", serviceName).apply()
        connect(endpoint.host, endpoint.port)
    }
    private fun connect(host: String, port: Int) {
        endpoint = host to port
        val prefs = context!!.getSharedPreferences("androp", Context.MODE_PRIVATE)
        val code = prefs.getString("code", "").orEmpty()
        prefs.edit().putString("host", host).putInt("port", port).apply()
        runCatching { client.connect(host, port, code) }.onFailure { message = "Invalid Mac address" }
    }
    private fun scheduleReconnect() {
        if (users == 0 || endpoint == null || reconnect?.isActive == true) return
        reconnect = scope.launch {
            delay(12_000)
            endpoint?.let { connect(it.first, it.second) }
            reconnect = null
        }
    }
    fun receivingEdge(phoneEdge: String) = when (phoneEdge) {
        "RIGHT" -> "LEFT"
        "TOP" -> "BOTTOM"
        "BOTTOM" -> "TOP"
        else -> "RIGHT"
    }
    fun enter(content: TransferContent, id: String = UUID.randomUUID().toString(), phoneEdge: String = "LEFT"): String {
        check(isConnected) { "Connect to your Mac first" }
        waiting[id] = CompletableDeferred()
        if (!client.sendDragEnter(DragEnterPacket(id, content.name.take(255), content.mime, content.thumbnail, receivingEdge(phoneEdge)))) {
            waiting.remove(id)
            error("Connection lost")
        }
        return id
    }
    suspend fun commit(id: String, content: TransferContent, onProgress: (Long, Long?, Long) -> Unit = { _, _, _ -> }): String {
        val result = waiting.getOrPut(id) { CompletableDeferred() }
        val signals = UploadSignals()
        uploads[id] = signals
        try {
            if (result.isCompleted) return result.await()
            check(client.sendControl(JSONObject().put("type", "DRAG_RELEASE").put("id", id)
                .put("action", "COMMIT").put("velocityX", 0).put("velocityY", 0)
                .put("stream", true).apply { content.size?.let { put("size", it) } })) { "Connection lost" }
            withTimeout(60_000) { signals.ready.await() }
            val summary = withContext(Dispatchers.IO) {
                val digest = MessageDigest.getInstance("SHA-256")
                var sent = 0L
                var lastProgress = 0L
                val started = android.os.SystemClock.elapsedRealtime()
                val buffer = ByteArray(256 * 1024)
                val inFlight = ArrayDeque<Long>()
                var eof = false
                content.open(requireNotNull(context)).use { input ->
                    while (!eof || inFlight.isNotEmpty()) {
                        // Fill a small sliding window; don't wait for one Wi-Fi RTT per chunk.
                        while (!eof && inFlight.size < CHUNKS_IN_FLIGHT) {
                            ensureActive()
                            val count = input.read(buffer)
                            if (count == -1) { eof = true; break }
                            if (count == 0) continue
                            check(client.sendChunk(buffer, count)) { "Connection lost" }
                            digest.update(buffer, 0, count)
                            sent += count
                            inFlight.addLast(sent)
                        }
                        if (inFlight.isEmpty()) break
                        val received = withTimeout(60_000) { signals.acknowledgements.receive() }
                        check(received == inFlight.removeFirst()) { "Transfer acknowledgement mismatch" }
                        val now = android.os.SystemClock.elapsedRealtime()
                        if (now - lastProgress >= 120 || (eof && inFlight.isEmpty())) {
                            lastProgress = now
                            val rate = (received.toDouble() * 1000 / (now - started).coerceAtLeast(1)).toLong()
                            withContext(Dispatchers.Main) { onProgress(received, content.size, rate) }
                        }
                    }
                }
                sent to digest.digest().joinToString("") { "%02x".format(it) }
            }
            check(client.sendControl(JSONObject().put("type", "TRANSFER_END").put("id", id)
                .put("bytes", summary.first).put("sha256", summary.second))) { "Connection lost" }
            return withTimeout(60_000) { result.await() }
        } finally {
            waiting.remove(id)
            uploads.remove(id)
            signals.acknowledgements.cancel()
            if (!result.isCompleted) cancel(id)
        }
    }
    fun cancel(id: String) {
        waiting.remove(id)?.cancel()
        uploads[id]?.fail(CancellationException("Transfer cancelled"))
        client.sendDragRelease(DragReleasePacket(id, "CANCEL", 0f, 0f))
    }
}
