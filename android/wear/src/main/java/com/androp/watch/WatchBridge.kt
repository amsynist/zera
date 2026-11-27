package com.androp.watch

import android.app.*
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

internal const val PHONE_CAPABILITY = "zerax_approval_phone"
internal const val REQUEST_PATH = "/zerax/approval/request"
internal const val STATE_PATH = "/zerax/approval/state"

internal data class WatchApproval(val id: String, val project: String, val summary: String, val actionable: Boolean)
internal data class WatchState(
    val connected: Boolean = false, val items: List<WatchApproval> = emptyList(), val result: String? = null,
    val receivedAt: Long = 0, val sentAt: Long = 0
)

internal object WatchBridge {
    private val handler = Handler(Looper.getMainLooper())
    var state = WatchState()
        private set
    var onChange: (() -> Unit)? = null
    private var lastSentAt = 0L

    fun phone(context: Context) = context.getSharedPreferences("approval_watch", 0).getString("phone", null)

    fun link(context: Context, id: String) {
        if (phone(context) == id) return
        context.getSharedPreferences("approval_watch", 0).edit().putString("phone", id).apply()
        state = WatchState()
        lastSentAt = 0
    }

    fun send(context: Context, body: JSONObject, failed: (() -> Unit)? = null) {
        val phone = phone(context) ?: run { failed?.invoke(); return }
        Wearable.getNodeClient(context).connectedNodes.addOnSuccessListener { nodes ->
            if (phone(context) != phone || nodes.none { it.id == phone && it.isNearby }) { failed?.invoke(); return@addOnSuccessListener }
            Wearable.getMessageClient(context).sendMessage(phone, REQUEST_PATH, body.toString().toByteArray())
                .addOnFailureListener { failed?.invoke() }
        }.addOnFailureListener { failed?.invoke() }
    }

    fun refresh(context: Context, failed: (() -> Unit)? = null) = send(context, JSONObject().put("type", "refresh"), failed)

    fun apply(context: Context, payload: JSONObject) {
        val now = System.currentTimeMillis()
        val sent = payload.optLong("sentAt")
        if (sent <= lastSentAt || sent < now - 45_000 || sent > now + 10_000) return
        val raw = payload.optJSONArray("approvals") ?: return
        if (raw.length() > 3) return
        val items = runCatching {
            List(raw.length()) {
                val item = raw.getJSONObject(it)
                WatchApproval(item.getString("id"), item.getString("project"), item.getString("summary"), item.getBoolean("actionable"))
            }
        }.getOrNull() ?: return
        lastSentAt = sent
        val previous = state.items
        state = WatchState(payload.optBoolean("connected"), items,
            payload.optString("result").takeIf(String::isNotBlank), SystemClock.elapsedRealtime(), sent)
        val manager = context.getSystemService(NotificationManager::class.java)
        if (items.isEmpty()) manager.cancel(19)
        else if (items.any { item -> previous.none { it.id == item.id } } &&
            (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)) {
            val channel = NotificationChannel("watch-approvals", "Claude approvals", NotificationManager.IMPORTANCE_HIGH)
            channel.enableVibration(true)
            manager.createNotificationChannel(channel)
            val open = Intent(context, WatchActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val intent = PendingIntent.getActivity(context, 19, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            runCatching {
                // Full screen: the approval face takes over the watch like an incoming call. Without
                // pop-up access Wear OS shows the alert instead, and tapping it opens the same face.
                manager.notify(19, Notification.Builder(context, channel.id).setSmallIcon(R.drawable.ic_signal_zera)
                    .setContentTitle("Claude needs you").setContentText("Slide to approve or deny").setContentIntent(intent)
                    .setFullScreenIntent(intent, true).setCategory(Notification.CATEGORY_REMINDER)
                    .addAction(Notification.Action.Builder(null, "Review", intent).build())
                    .setLocalOnly(true).setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true).build())
            }
        }
        onChange?.invoke()
        if (items.isNotEmpty()) handler.postDelayed({
            if (state.sentAt != sent) return@postDelayed
            state = WatchState(result = "Connection expired")
            manager.cancel(19)
            onChange?.invoke()
        }, 45_000)
    }
}

class WatchWearListener : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != STATE_PATH || event.data.size > 4096) return
        val sender = event.sourceNodeId
        if (sender != WatchBridge.phone(this)) return
        val payload = runCatching { JSONObject(String(event.data, Charsets.UTF_8)) }.getOrNull() ?: return
        Wearable.getNodeClient(this).connectedNodes.addOnSuccessListener { nodes ->
            if (sender == WatchBridge.phone(this) && nodes.any { it.id == sender && it.isNearby }) {
                WatchBridge.apply(applicationContext, payload)
            }
        }
    }
}
