package com.androp.approvals

import android.app.*
import android.Manifest
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.androp.R
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONArray
import org.json.JSONObject

class ApprovalService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var worker: Job? = null
    private var connection: ApprovalConnection? = null
    private var authenticated = false
    private var generation = 0
    private var lastWatchTimestamp = 0L
    private var pendingWatchWideResult = false
    private val notifications get() = getSystemService(NotificationManager::class.java)

    override fun onBind(intent: Intent?): IBinder? = null

    private val networkKick = Channel<Unit>(Channel.CONFLATED)
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ApprovalStore.load(this)
        val pairing = Approvals.pairing
        if (pairing == null) { stopSelf(); return START_NOT_STICKY }
        Approvals.service = this
        notifications.createNotificationChannel(NotificationChannel("approvals-link", "Mac approval connection", NotificationManager.IMPORTANCE_LOW))
        notifications.createNotificationChannel(NotificationChannel("approvals-request", "Claude approvals", NotificationManager.IMPORTANCE_HIGH))
        startForeground(72, notification("Mac approvals enabled", "Tap to open Zera X", "approvals-link").setOngoing(true).build())
        if (networkCallback == null) {
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) { networkKick.trySend(Unit) }
            }
            if (runCatching { getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(callback) }.isSuccess) {
                networkCallback = callback
            }
        }
        if (worker?.isActive != true) {
            val ticket = ++generation
            worker = scope.launch { connectUntilStopped(pairing, ticket) }
        }
        return START_STICKY
    }

    private suspend fun connectUntilStopped(paired: ApprovalPairing, ticket: Int) {
        var pairing = paired
        var retry = 2L
        while (currentCoroutineContext().isActive && ticket == generation) {
            setState(ApprovalState(running = true, status = "Connecting to Mac…"))
            val link = ApprovalConnection(pairing)
            connection = link
            try {
                link.connect()
                coroutineScope {
                    val ping = launch(Dispatchers.IO) {
                        while (isActive) {
                            delay(60_000)
                            try { link.send(JSONObject().put("type", "ping")) }
                            catch (_: Exception) { link.close(); return@launch }
                        }
                    }
                    try {
                        while (isActive) {
                            val message = withContext(Dispatchers.IO) { link.receive() }
                            if (ticket != generation) return@coroutineScope
                            handle(message)
                            retry = 2
                        }
                    } finally { ping.cancel() }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // A dropped connection never carries a decision over to its replacement.
                // If the Mac moved to another address or port, find it by its key over Bonjour.
                if (!authenticated && ticket == generation) {
                    MacFinder.find(this, pairing.fingerprint)?.let { (host, port) ->
                        if (host != pairing.host || port != pairing.port) {
                            pairing = pairing.moved(host, port)
                            ApprovalStore.savePairing(this, pairing)
                            retry = 1
                        }
                    }
                }
            } finally {
                link.close()
                if (connection === link) connection = null
            }
            authenticated = false
            pendingWatchWideResult = false
            if (ticket != generation) return
            setState(ApprovalState(running = true, status = "Mac disconnected · retrying"))
            clearNotification()
            publishWatch("Mac disconnected")
            // Away from the Mac, back off to one try every five minutes. Joining a network
            // (home Wi-Fi, the Mac's hotspot) wakes the loop at once instead.
            if (withTimeoutOrNull(retry * 1000) { networkKick.receive() } != null) retry = 2
            else retry = (retry * 2).coerceAtMost(300)
        }
    }

    private fun handle(message: JSONObject) {
        when (message.optString("type")) {
            "snapshot" -> {
                val items = message.getJSONArray("approvals")
                val before = Approvals.state.value.approvals
                val after = List(items.length()) { Approval.parse(items.getJSONObject(it)) }
                authenticated = true
                setState(Approvals.state.value.copy(connected = true, status = "Mac connected", approvals = after))
                if (after.isEmpty()) clearNotification()
                else if (after.any { req -> before.none { it.id == req.id } }) notifyReview()
                publishWatch()
            }
            "result" -> {
                val id = message.getString("id")
                if (Approvals.state.value.awaiting != id) return
                val code = message.getString("result")
                val filtered = if (code in setOf("approved", "denied", "handled")) Approvals.state.value.approvals.filterNot { it.id == id }
                    else Approvals.state.value.approvals
                val text = when (code) {
                    "approved" -> "Approved in Zera"
                    "denied" -> "Denied in Zera"
                    "handled" -> "Already handled or expired"
                    "phone" -> "Review this request on your phone"
                    else -> "Decision wasn’t accepted · try again"
                }
                setState(Approvals.state.value.copy(status = text, awaiting = null, approvals = filtered))
                publishWatch(if (pendingWatchWideResult) text else null)
                pendingWatchWideResult = false
            }
            "pong" -> if (Approvals.state.value.approvals.isNotEmpty()) publishWatch()
        }
    }

    internal fun decide(id: String, allow: Boolean, watch: Boolean) {
        val state = Approvals.state.value
        val link = connection ?: return
        val request = state.approvals.firstOrNull { it.id == id } ?: run { publishWatch("Already handled or expired"); return }
        if (!authenticated || state.awaiting != null || (watch && !request.watchActionable)) return
        setState(state.copy(awaiting = id, status = "Sending decision…"))
        pendingWatchWideResult = watch
        scope.launch(Dispatchers.IO) {
            try { link.send(JSONObject().put("type", "decision").put("id", id).put("allow", allow).put("watch", watch)) }
            catch (_: Exception) { link.close() }
        }
        scope.launch {
            delay(10_000)
            if (connection === link && Approvals.state.value.awaiting == id) {
                val status = "No confirmation · check the Mac"
                setState(Approvals.state.value.copy(awaiting = null, status = status))
                if (pendingWatchWideResult) publishWatch(status)
                pendingWatchWideResult = false
            }
        }
    }

    internal fun publishWatch(result: String? = null) {
        val target = Approvals.watchId ?: return
        val state = Approvals.state.value
        val items = JSONArray()
        state.approvals.forEach { items.put(it.forWatch()) }
        lastWatchTimestamp = maxOf(System.currentTimeMillis(), lastWatchTimestamp + 1)
        val payload = JSONObject().put("sentAt", lastWatchTimestamp)
            .put("connected", state.connected).put("approvals", items)
        if (result != null) payload.put("result", result)
        Wearable.getNodeClient(this).connectedNodes.addOnSuccessListener { nodes ->
            if (Approvals.watchId == target && nodes.any { it.id == target && it.isNearby }) {
                Wearable.getMessageClient(this).sendMessage(target, WATCH_STATE, payload.toString().toByteArray())
            }
        }
    }

    internal fun refreshWatchSelection() {
        setState(Approvals.state.value)
        publishWatch()
    }

    private fun setState(state: ApprovalState) { Approvals.state.value = state.copy(watchName = Approvals.watchName) }

    internal fun notifyReview() {
        if (Approvals.state.value.approvals.isEmpty()) return
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        notifications.notify(73, notification("Claude needs you", "Open Zera X to review", "approvals-request").setAutoCancel(true).build())
    }

    private fun notification(title: String, summary: String, channel: String): NotificationCompat.Builder {
        val open = PendingIntent.getActivity(this, 72, Intent(this, ApprovalsActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, channel).setSmallIcon(R.drawable.ic_signal_zera)
            .setContentTitle(title).setContentText(summary).setContentIntent(open).setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setLocalOnly(true)
    }

    private fun clearNotification() { notifications.cancel(73) }

    override fun onDestroy() {
        networkCallback?.let { runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } }
        networkCallback = null
        generation++
        connection?.close()
        connection = null
        clearNotification()
        setState(ApprovalState())
        publishWatch("Approval link off")
        if (Approvals.service === this) Approvals.service = null
        scope.cancel()
        super.onDestroy()
    }
}
