package com.androp.network

import okhttp3.*
import org.json.JSONObject
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit

class StreamClient(
    private val onState: (Boolean, String) -> Unit,
    private val onResult: (String, Boolean, String) -> Unit,
    private val onSignal: (String, String, Long) -> Unit
) {
    private val client = OkHttpClient.Builder().pingInterval(15, TimeUnit.SECONDS)
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
        onState(false, "Connecting to your Mac…")
        socket = client.newWebSocket(request, object : WebSocketListener() {
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
                        onState(isConnected, if (isConnected) "Your Mac is within reach" else if (json.optBoolean("ok")) "Update Androp on your Mac to enable streaming" else "Check the pairing code in the Mac menu")
                    }
                    "TRANSFER_READY", "CHUNK_ACK" -> onSignal(json.optString("id"), json.optString("type"), json.optLong("received"))
                    "RESULT" -> onResult(json.optString("id"), json.optBoolean("ok"),
                        if (json.optBoolean("ok")) "Saved on your Mac" else json.optString("error", "Transfer failed"))
                }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { lost("Mac disconnected") }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { lost("Can't reach Mac · check Wi-Fi and code") }
            private fun lost(message: String) {
                if (epoch == generation) { isConnected = false; onState(false, message) }
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
