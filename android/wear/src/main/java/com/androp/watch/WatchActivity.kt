package com.androp.watch

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject

class WatchActivity : Activity() {
    private enum class Outcome { Approved, Denied, Info }

    private lateinit var face: ApprovalFace
    private var sending: WatchApproval? = null
    private var status: String? = null
    private var outcome: Outcome? = null
    private var outcomeText = ""
    private var seenResult: String? = null
    private var shownRequest: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        face = ApprovalFace(this)
        setContentView(face)
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !getPreferences(0).getBoolean("asked_notifications", false)) {
            getPreferences(0).edit().putBoolean("asked_notifications", true).apply()
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onStart() {
        super.onStart()
        seenResult = WatchBridge.state.result
        WatchBridge.onChange = { changed() }
        refresh()
        render()
    }

    override fun onStop() {
        WatchBridge.onChange = null
        face.removeCallbacks(closeAfterResult)
        super.onStop()
    }

    private fun changed() {
        val state = WatchBridge.state
        val result = state.result
        if (result != null && result != seenResult) {
            seenResult = result
            outcomeText = result
            outcome = when {
                result.startsWith("Approved") -> Outcome.Approved
                result.startsWith("Denied") -> Outcome.Denied
                else -> Outcome.Info
            }
            sending = null
            face.removeCallbacks(closeAfterResult)
            face.postDelayed(closeAfterResult, 2_000)
        } else if (state.items.none { it.id == sending?.id }) {
            sending = null
        }
        status = null
        render()
    }

    private val closeAfterResult = Runnable {
        outcome = null
        if (WatchBridge.state.items.isEmpty() && !isFinishing) finish() else render()
    }

    private fun refresh() {
        Wearable.getCapabilityClient(this).getCapability(PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { capability ->
                if (isDestroyed || isFinishing) return@addOnSuccessListener
                val phone = capability.nodes.singleOrNull { it.isNearby }
                if (phone == null) { status = "Phone not nearby"; render(); return@addOnSuccessListener }
                WatchBridge.link(this, phone.id)
                WatchBridge.refresh(this) { status = "Phone disconnected"; render() }
            }
            .addOnFailureListener { if (!isDestroyed) { status = "Wear OS link unavailable"; render() } }
    }

    private fun render() {
        if (isDestroyed || isFinishing) return
        val state = WatchBridge.state
        face.apply {
            happy = false; hint = ""; tapLabel = ""; verb = ""; target = ""; caption = ""
            control = ApprovalFace.Control.None
            onApprove = null; onDeny = null; onTap = null
        }
        val pending = sending
        val result = outcome
        val request = state.items.firstOrNull()
        when {
            pending != null -> face.apply {
                ring = ApprovalFace.Ring.Busy
                setAction(pending)
                caption = "Sending…"
            }
            result != null -> face.apply {
                when (result) {
                    Outcome.Approved -> { ring = ApprovalFace.Ring.Approved; verb = "Approved" }
                    Outcome.Denied -> { ring = ApprovalFace.Ring.Denied; verb = "Denied" }
                    Outcome.Info -> { ring = ApprovalFace.Ring.Idle; target = outcomeText.substringBefore(" · ") }
                }
            }
            request != null -> face.apply {
                ring = ApprovalFace.Ring.Waiting
                val count = if (state.items.size > 1) " · 1/${state.items.size}" else ""
                caption = request.project + count
                if (request.actionable) {
                    setAction(request)
                    if (canDecide()) {
                        control = ApprovalFace.Control.Slide
                        onApprove = { decide(request, true) }
                        onDeny = { decide(request, false) }
                    } else {
                        control = ApprovalFace.Control.Tap
                        tapLabel = "Unlock watch"
                        onTap = { getSystemService(KeyguardManager::class.java).requestDismissKeyguard(this@WatchActivity, null) }
                    }
                } else {
                    verb = "Claude"
                    target = "Check phone"
                    control = ApprovalFace.Control.Tap
                    status?.let { caption = it }
                    onTap = {
                        WatchBridge.send(this@WatchActivity, JSONObject().put("type", "review")) { status = "Phone disconnected"; render() }
                        status = "Sent to your phone"
                        render()
                    }
                }
            }
            else -> face.apply {
                ring = ApprovalFace.Ring.Idle
                verb = "Zera X"
                target = status ?: if (state.connected) "All clear" else "Not linked"
                if (state.connected && status == null && !canPopUp()) {
                    control = ApprovalFace.Control.Tap
                    tapLabel = "Allow pop-up alerts"
                    onTap = {
                        runCatching { startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName"))) }
                            .onFailure { status = "Allow in Settings"; render() }
                    }
                } else if (status != null || !state.connected) {
                    control = ApprovalFace.Control.Tap
                    tapLabel = "Tap to retry"
                    onTap = { status = "Connecting…"; render(); refresh() }
                }
            }
        }
        val showing = (pending ?: request)?.id
        if (showing != null && showing != shownRequest && result == null) face.enter()
        shownRequest = showing
        if (request != null || pending != null) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        face.update()
    }

    private fun ApprovalFace.setAction(request: WatchApproval) {
        val summary = request.summary.trim()
        verb = summary.substringBefore(' ')
        target = summary.substringAfter(' ', "")
    }

    /** A watch without a screen lock is never locked. With one, approvals wait for an unlock. */
    private fun canDecide(): Boolean = !getSystemService(KeyguardManager::class.java).isDeviceLocked

    private fun canPopUp(): Boolean =
        Build.VERSION.SDK_INT < 34 || getSystemService(NotificationManager::class.java).canUseFullScreenIntent()

    private fun decide(request: WatchApproval, allow: Boolean) {
        val state = WatchBridge.state
        if (!canDecide() || !state.connected || SystemClock.elapsedRealtime() - state.receivedAt >= 45_000 ||
            state.items.none { it == request } || sending != null) {
            outcome = Outcome.Info; outcomeText = "Request unavailable"
            face.postDelayed(closeAfterResult, 2_000)
            render(); return
        }
        sending = request
        render()
        val body = JSONObject().put("type", "decision").put("id", request.id).put("allow", allow)
        WatchBridge.send(this, body) {
            if (sending?.id == request.id) { sending = null; outcome = Outcome.Info; outcomeText = "Couldn’t send"; render() }
        }
        face.postDelayed({
            if (sending?.id == request.id) { sending = null; outcome = Outcome.Info; outcomeText = "Check your Mac"; render(); refresh() }
        }, 10_000)
    }
}
