package com.androp.network

import okhttp3.*
import org.json.JSONObject
import okio.ByteString.Companion.toByteString
import java.net.Proxy
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

class StreamClient(
    private val onState: (Boolean, String, Boolean) -> Unit,
    private val onResult: (String, Boolean, String) -> Unit,
    private val onSignal: (String, String, Long) -> Unit
) {
    private val client = OkHttpClient.Builder().pingInterval(15, TimeUnit.SECONDS)
        .proxy(Proxy.NO_PROXY).followRedirects(false)
        .connectTimeout(5, TimeUnit.SECONDS).build()
    @Volatile private var socket: WebSocket? = null
    @Volatile private var generation = 0
    @Volatile var isConnected = false
        private set

    @Synchronized fun connect(host: String, port: Int, code: String) {
        disconnect()
        val epoch = generation
        val address = host.trim().removePrefix("[").removeSuffix("]")
        val authority = if (address.contains(':')) "[$address]" else address
        val request = Request.Builder().url("ws://$authority:$port").build()
        onState(false, "Connecting to $authority:$port…", false)
        socket = client.newWebSocket(request, object : WebSocketListener() {
            private var authRejected = false
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (epoch != generation) { webSocket.cancel(); return }
                webSocket.send(JSONObject().put("type", "HELLO").put("code", code).put("version", 3).toString())
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (epoch != generation) return
                val json = runCatching { JSONObject(text) }.getOrNull() ?: return
                when (json.optString("type")) {
                    "AUTH" -> {
                        isConnected = json.optBoolean("ok") && json.optInt("version") >= 3
                        authRejected = !isConnected
                        val message = when {
                            isConnected -> "Connected to your Mac"
                            json.optBoolean("ok") -> "Update Zera on your Mac to enable streaming"
                            else -> "Pairing rejected. Check the six-digit code in Zera or scan its QR again."
                        }
                        onState(isConnected, message, false)
                    }
                    "TRANSFER_READY", "CHUNK_ACK" -> onSignal(json.optString("id"), json.optString("type"), json.optLong("received"))
                    "RESULT" -> onResult(json.optString("id"), json.optBoolean("ok"),
                        if (json.optBoolean("ok")) "Saved on your Mac" else json.optString("error", "Transfer failed"))
                }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { lost("Mac disconnected") }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val message = when {
                    response != null -> "$authority:$port didn’t accept Androp. Check that Zera is receiving on this address."
                    t is UnknownHostException -> "Mac name not found. Use the local IP address shown in Zera."
                    else -> "Can’t reach $authority:$port. Use the same Wi-Fi or phone hotspot and turn on receiving in Zera."
                }
                lost(message)
            }
            private fun lost(message: String) {
                if (epoch == generation && !authRejected) { isConnected = false; onState(false, message, true) }
            }
        })
    }

    @Synchronized fun disconnect() {
        generation++
        socket?.close(1000, "Leaving")
        socket = null
        isConnected = false
    }
    fun sendControl(json: JSONObject) = isConnected && socket?.send(json.toString()) == true
    fun sendChunk(bytes: ByteArray, count: Int) = isConnected && socket?.send(bytes.toByteString(0, count)) == true
    fun sendDragEnter(packet: DragEnterPacket) = isConnected && socket?.send(packet.toJson()) == true
    fun sendDragUpdate(packet: DragUpdatePacket) = isConnected && socket?.send(packet.toJson()) == true
    fun sendDragRelease(packet: DragReleasePacket) = isConnected && socket?.send(packet.toJson()) == true
}
