package com.androp.overlay

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.os.*
import android.provider.Settings
import android.util.Log
import android.view.*
import android.widget.Toast
import androidx.core.app.NotificationCompat
import com.androp.network.*
import com.androp.ui.EdgeRippleView
import com.androp.ui.MainActivity
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.UUID

/** Four invisible 6px seams expand into forgiving drop targets during a global drag. */
class EdgeOverlayService : Service() {
    companion object {
        @Volatile var isRunning = false
            private set
        val status = MutableStateFlow("All four edges · receiver off")
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var windows: WindowManager
    private val strips = mutableListOf<View>()
    private var ripple: EdgeRippleView? = null
    private val fadingRipples = mutableSetOf<View>()
    private var transferId: String? = null
    private var dragActive = false
    private var activeEdge: String? = null
    private var acquired = false
    private var ready = false
    private var lastUpdate = 0L
    /** Where the item was and how much of it had crossed, so the catch starts at the same split. */
    private var lastCoordinate = 0.5f
    private var lastCrossed = 0f
    private var previewJob: Job? = null
    private val observer: (Boolean, String) -> Unit = { connected, message ->
        if (ready) updateStatus(if (connected) "All four edges ready · waiting for a system drag" else "Mac offline · $message")
    }
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        if (!Settings.canDrawOverlays(this)) { updateStatus("Allow display over other apps to enable the receiver"); stopSelf(); return }
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("edge", "Androp edge sharing", NotificationManager.IMPORTANCE_LOW))
        if (Build.VERSION.SDK_INT >= 29) startForeground(41, notification("Connecting to your Mac…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(41, notification("Connecting to your Mac…"))
        windows = getSystemService(WindowManager::class.java)
        AndropConnection.acquire(this); acquired = true; ready = true
        runCatching {
            for (edge in listOf("LEFT", "RIGHT", "TOP", "BOTTOM")) attachEdge(edge)
            isRunning = true
            AndropConnection.observe(observer)
        }.onFailure { updateStatus("Couldn't show the receiver · check overlay permission"); stopSelf() }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!isRunning) { stopSelf(); return START_NOT_STICKY }
        when (intent?.action) { "STOP" -> stopSelf(); "PREVIEW" -> preview() }
        return START_STICKY
    }
    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, EdgeOverlayService::class.java).setAction("STOP"), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, "edge").setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Androp · all edges active").setContentText(text).setContentIntent(open)
            .setOngoing(true).setSilent(true).addAction(0, "Turn off", stop).build()
    }
    private fun updateStatus(text: String) {
        status.value = text
        Log.i("AndropEdge", text)
        if (ready) getSystemService(NotificationManager::class.java).notify(41, notification(text))
    }
    private fun attachEdge(edge: String) {
        val horizontal = edge == "TOP" || edge == "BOTTOM"
        val params = WindowManager.LayoutParams(if (horizontal) -1 else 6, if (horizontal) 6 else -1,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT).apply {
            gravity = when (edge) { "RIGHT" -> Gravity.RIGHT or Gravity.TOP; "TOP" -> Gravity.TOP or Gravity.LEFT; "BOTTOM" -> Gravity.BOTTOM or Gravity.LEFT; else -> Gravity.LEFT or Gravity.TOP }
        }
        val view = View(this).apply {
            tag = edge
            contentDescription = "Androp ${edge.lowercase()} drop edge"
            setOnDragListener { target, event -> onDrag(target, event, edge) }
            setOnTouchListener { _, _ -> false }
        }
        windows.addView(view, params)
        strips.add(view)
    }
    private fun resizeTargets(active: Boolean) {
        val thickness = if (active) (64 * resources.displayMetrics.density).toInt() else 6
        strips.forEach { view ->
            val params = view.layoutParams as WindowManager.LayoutParams
            if (view.tag == "TOP" || view.tag == "BOTTOM") params.height = thickness else params.width = thickness
            windows.updateViewLayout(view, params)
        }
    }
    private fun showRipple(edge: String, coordinate: Float) {
        if (ripple == null || ripple?.edge != edge) {
            hideRipple(false)
            ripple = EdgeRippleView(this).apply { this.edge = edge }
            windows.addView(ripple, WindowManager.LayoutParams(-1, -1, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT).apply { alpha = 0.65f })
        }
        ripple?.approach(coordinate)
    }
    private fun hideRipple(commit: Boolean) {
        val view = ripple ?: return
        ripple = null
        view.release(commit)
        fadingRipples.add(view)
        scope.launch {
            delay(if (commit) 1100 else 240)
            runCatching { windows.removeView(view) }
            fadingRipples.remove(view)
        }
    }
    private fun cancelPreview() {
        transferId?.let { AndropConnection.cancel(it) }
        transferId = null
        activeEdge = null
    }
    private fun preview() {
        previewJob?.cancel()
        cancelPreview()
        showRipple("LEFT", 0.5f)
        if (AndropConnection.isConnected) {
            runCatching { transferId = AndropConnection.enter(TransferContent.text(""), phoneEdge = "LEFT") }
            transferId?.let { AndropConnection.client.sendDragUpdate(DragUpdatePacket(it, 0.5f, 0.6f, 0f, 0f)) }
            updateStatus("Test glow sent to Mac · now try a Gallery drag")
        } else updateStatus("Phone overlay works · connect to your Mac before sending")
        previewJob = scope.launch { delay(1800); cancelPreview(); hideRipple(false) }
    }
    /**
     * How much of the drag shadow is already clipped off this edge. Android centres the shadow on the
     * finger and only reports the finger, so a typical shadow width stands in: nothing crosses until
     * the finger is half a shadow from the edge, and half the picture is past it at the very edge.
     * The Mac shows exactly this share, like one picture spanning two screens.
     */
    private fun crossed(view: View, event: DragEvent, edge: String): Float {
        val distance = when (edge) {
            "RIGHT" -> view.width - event.x
            "TOP" -> event.y
            "BOTTOM" -> view.height - event.y
            else -> event.x
        }
        val shadow = 160 * resources.displayMetrics.density
        return ((shadow / 2 - distance) / shadow).coerceIn(0f, 0.5f)
    }
    private fun onDrag(view: View, event: DragEvent, edge: String): Boolean {
        val coordinate = (if (edge == "TOP" || edge == "BOTTOM") event.x / view.width else event.y / view.height).coerceIn(0f, 1f)
        when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> {
                if (!dragActive) {
                    dragActive = true
                    previewJob?.cancel()
                    cancelPreview()
                    showRipple("AUTO", 0.5f)
                    resizeTargets(true)
                    updateStatus(if (AndropConnection.isConnected) "System drag detected · glide into any illuminated edge" else "System drag detected · Mac is disconnected")
                }
                // Always accept the start event, including while offline, so a failed connection is visible.
                return true
            }
            DragEvent.ACTION_DRAG_ENTERED -> {
                cancelPreview()
                activeEdge = edge
                showRipple(edge, coordinate)
                updateStatus(if (AndropConnection.isConnected) "${edge.lowercase().replaceFirstChar { it.uppercase() }} edge ready · let go to send" else "Mac disconnected · photo will stay on your phone")
                if (AndropConnection.isConnected) {
                    val id = UUID.randomUUID().toString()
                    val name = event.clipDescription?.label?.toString()?.take(180)?.ifBlank { "Incoming file" } ?: "Incoming file"
                    // The picture itself is only readable at the drop; the type lets the Mac shape the card now.
                    val mime = event.clipDescription?.takeIf { it.mimeTypeCount > 0 }?.getMimeType(0) ?: "application/octet-stream"
                    if (AndropConnection.client.sendDragEnter(DragEnterPacket(id, name, mime, "", AndropConnection.receivingEdge(edge)))) transferId = id
                    lastCoordinate = coordinate; lastCrossed = crossed(view, event, edge)
                    transferId?.let { AndropConnection.client.sendDragUpdate(DragUpdatePacket(it, coordinate, lastCrossed, 0f, 0f)) }
                }
            }
            DragEvent.ACTION_DRAG_LOCATION -> {
                showRipple(edge, coordinate)
                val now = SystemClock.uptimeMillis()
                if (now - lastUpdate >= 16) {
                    lastCoordinate = coordinate; lastCrossed = crossed(view, event, edge)
                    transferId?.let { AndropConnection.client.sendDragUpdate(DragUpdatePacket(it, coordinate, lastCrossed, 0f, 0f)) }
                    lastUpdate = now
                }
            }
            DragEvent.ACTION_DROP -> {
                if (!AndropConnection.isConnected || event.clipData == null || event.clipData.itemCount != 1) {
                    updateStatus(if (!AndropConnection.isConnected) "Connect to your Mac, then try again" else "Drop one file at a time")
                    Toast.makeText(this, status.value, Toast.LENGTH_LONG).show()
                    cancelPreview(); hideRipple(false); return false
                }
                val id = transferId
                transferId = null; activeEdge = null
                hideRipple(true)
                runCatching {
                    startActivity(Intent(this, EdgeDropActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
                        putExtra("drop", event); putExtra("transferId", id); putExtra("phoneEdge", edge)
                        putExtra("coordinate", coordinate); putExtra("crossed", lastCrossed)
                    })
                }.onFailure { id?.let { AndropConnection.cancel(it) }; updateStatus("Android blocked the drop handoff · use Share → Androp"); return false }
                updateStatus("Caught · push it to your Mac, or drag it back to cancel")
                return true
            }
            DragEvent.ACTION_DRAG_EXITED -> if (activeEdge == edge) { cancelPreview(); showRipple("AUTO", 0.5f) }
            DragEvent.ACTION_DRAG_ENDED -> {
                if (dragActive) {
                    dragActive = false
                    cancelPreview(); hideRipple(false)
                    resizeTargets(false)
                }
            }
        }
        return true
    }
    override fun onDestroy() {
        ready = false
        cancelPreview()
        strips.forEach { runCatching { windows.removeView(it) } }; strips.clear()
        ripple?.let { runCatching { windows.removeView(it) } }
        fadingRipples.forEach { runCatching { windows.removeView(it) } }; fadingRipples.clear()
        scope.cancel()
        isRunning = false
        status.value = "All four edges · receiver off"
        if (acquired) { AndropConnection.removeObserver(observer); AndropConnection.release() }
        super.onDestroy()
    }
}
