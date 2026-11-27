package com.androp.approvals

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.androp.R
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Wearable
import com.google.android.material.button.MaterialButton
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.*

class ApprovalsActivity : AppCompatActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var root: LinearLayout
    private lateinit var status: TextView
    private lateinit var pairingButton: MaterialButton
    private lateinit var watchButton: MaterialButton
    private lateinit var requests: LinearLayout
    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { startBridge() }
    private val scanner = registerForActivityResult(ScanContract()) { result ->
        result.contents?.let { text ->
            runCatching { ApprovalPairing.parse(text) }.onSuccess { pairing ->
                stopService(Intent(this, ApprovalService::class.java))
                ApprovalStore.savePairing(this, pairing)
                if (Build.VERSION.SDK_INT >= 33 &&
                    ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else startBridge()
            }.onFailure { status.text = it.message ?: "Invalid approval QR" }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val scroll = ScrollView(this).apply { setBackgroundResource(R.drawable.signal_pane); isFillViewport = true }
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(16), dp(22), dp(24))
        }
        scroll.addView(root)
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        setContentView(scroll)
        root.button("Back to files") { finish() }
        root.label("Approvals", 25, color(R.color.signal_text)).typeface = resources.getFont(R.font.signal_semibold)
        root.addView(android.view.View(this).apply { setBackgroundColor(color(R.color.signal_trace)) },
            LinearLayout.LayoutParams(-1, dp(1)).apply { topMargin = dp(8); bottomMargin = dp(10) })
        status = root.label("", 14, color(R.color.signal_secondary))
        status.accessibilityLiveRegion = TextView.ACCESSIBILITY_LIVE_REGION_POLITE
        pairingButton = root.button("Pair with Mac") {
            if (Approvals.state.value.running || ApprovalStore.hasPairing(this)) {
                ApprovalStore.forget(this)
                stopService(Intent(this, ApprovalService::class.java))
            } else scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setPrompt("Scan the approval QR in Zera Settings → Extras").setBeepEnabled(false).setOrientationLocked(false))
        }
        watchButton = root.button("Link nearby watch") { chooseWatch() }
        requests = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(requests)
        ApprovalStore.resume(this)
        scope.launch { Approvals.state.collect { render(it) } }
    }

    private fun startBridge() {
        if (Approvals.pairing == null) return
        ContextCompat.startForegroundService(this, Intent(this, ApprovalService::class.java))
    }

    private fun chooseWatch() {
        Wearable.getCapabilityClient(this).getCapability(WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { capability ->
                if (isFinishing || isDestroyed) return@addOnSuccessListener
                val nodes = capability.nodes.filter { it.isNearby }.sortedBy { it.displayName }
                if (nodes.isEmpty()) { status.text = "Open Zera X on your Bluetooth-connected watch first."; return@addOnSuccessListener }
                AlertDialog.Builder(this).setTitle("Send approvals to")
                    .setItems(nodes.map { it.displayName }.toTypedArray()) { _, index ->
                        ApprovalStore.saveWatch(this, nodes[index].id, nodes[index].displayName)
                        Approvals.service?.refreshWatchSelection()
                        render(Approvals.state.value)
                    }
                    .setNegativeButton("Cancel", null).show()
            }.addOnFailureListener { if (!isDestroyed) status.text = "Wear OS link unavailable on this phone." }
    }

    private fun render(state: ApprovalState) {
        status.text = state.status
        pairingButton.text = if (state.running || ApprovalStore.hasPairing(this)) "Forget Mac" else "Pair with Mac"
        watchButton.text = Approvals.watchName?.let { "Watch · $it" } ?: "Link nearby watch"
        requests.removeAllViews()
        if (!state.connected) return
        if (state.approvals.isEmpty()) requests.label("No requests waiting", 16, color(R.color.signal_secondary))
        for (request in state.approvals) {
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16), dp(14), dp(16), dp(14))
                setBackgroundResource(R.drawable.signal_focus)
            }
            requests.addView(card, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) })
            card.label(request.tool, 17, color(R.color.signal_warning)).apply { typeface = resources.getFont(R.font.signal_semibold) }
            if (request.project.isNotBlank()) card.label(request.project, 14, color(R.color.signal_secondary))
            card.label(request.details, 13, color(R.color.signal_text)).apply {
                typeface = resources.getFont(R.font.signal_mono); setTextIsSelectable(true); setPadding(0, dp(8), 0, dp(8))
            }
            card.button("Approve once", primary = true) { confirm(request, true) }.isEnabled = state.awaiting == null
            card.button("Deny", danger = true) { confirm(request, false) }.isEnabled = state.awaiting == null
        }
    }

    private fun confirm(request: Approval, allow: Boolean) {
        AlertDialog.Builder(this)
            .setTitle(if (allow) "Approve this action once?" else "Deny this action?")
            .setMessage(request.tool + if (request.project.isBlank()) "" else " · " + request.project)
            .setPositiveButton(if (allow) "Approve once" else "Deny") { _, _ -> Approvals.service?.decide(request.id, allow, false) }
            .setNegativeButton("Cancel", null).show()
    }

    private fun LinearLayout.label(text: String, size: Int, color: Int): TextView =
        TextView(this@ApprovalsActivity).also { it.text = text; it.textSize = size.toFloat(); it.typeface = resources.getFont(R.font.signal_mono); it.setTextColor(color); addView(it) }

    private fun LinearLayout.button(text: String, primary: Boolean = false, danger: Boolean = false, action: () -> Unit) =
        MaterialButton(this@ApprovalsActivity).also {
            it.text = text; it.isAllCaps = false; it.minHeight = dp(48)
            it.backgroundTintList = null
            it.setBackgroundResource(if (primary) R.drawable.signal_primary else R.drawable.signal_control)
            it.setTextColor(color(when { primary -> R.color.signal_background; danger -> R.color.signal_danger; else -> R.color.signal_text }))
            it.typeface = resources.getFont(R.font.signal_semibold)
            it.setOnClickListener { action() }
            addView(it, LinearLayout.LayoutParams(-1, -2))
        }

    private fun color(id: Int) = ContextCompat.getColor(this, id)

    private fun dp(value: Int) = (value * resources.displayMetrics.density + .5f).toInt()

    override fun onDestroy() { scope.cancel(); super.onDestroy() }
}
