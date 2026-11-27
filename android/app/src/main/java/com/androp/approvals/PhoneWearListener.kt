package com.androp.approvals

import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

class PhoneWearListener : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        ApprovalStore.load(this)
        val sender = event.sourceNodeId
        if (event.path != WATCH_REQUEST || sender != Approvals.watchId || event.data.size > 1024) return
        val payload = runCatching { JSONObject(String(event.data, Charsets.UTF_8)) }.getOrNull() ?: return
        Wearable.getNodeClient(this).connectedNodes.addOnSuccessListener { nodes ->
            if (sender != Approvals.watchId || nodes.none { it.id == sender && it.isNearby }) return@addOnSuccessListener
            val service = Approvals.service ?: return@addOnSuccessListener
            when (payload.optString("type")) {
                "refresh" -> service.publishWatch()
                "review" -> service.notifyReview()
                "decision" -> {
                    val allow = payload.opt("allow") as? Boolean ?: return@addOnSuccessListener
                    service.decide(payload.optString("id"), allow, watch = true)
                }
            }
        }
    }
}
