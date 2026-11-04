package com.androp.overlay

import android.app.Activity
import android.graphics.BitmapFactory
import android.graphics.Outline
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Base64
import android.view.*
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.Toast
import com.androp.network.*
import kotlinx.coroutines.*

/**
 * Catches a system drag dropped on an edge. Android reveals the item only at the drop, so the drop
 * catches rather than sends: the real picture waits half off the phone's edge (at the same split on
 * the Mac) until it is pushed across to send, or dragged back / tapped away to keep it. Items without
 * a picture send at once. Drag URI permissions are retained until the original is read and acknowledged.
 */
class EdgeDropActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var permission: android.view.DragAndDropPermissions? = null
    private var id: String? = null
    private var content: TransferContent? = null
    private var edge = "LEFT"
    private var settled = false
    private var idle: Job? = null
    private var lastReport = 0L
    private lateinit var root: FrameLayout
    private lateinit var card: View
    private var caughtX = 0f
    private var caughtY = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setLayout(1, 1)
        @Suppress("DEPRECATION")
        val event = intent.getParcelableExtra<DragEvent>("drop")
        val previewId = intent.getStringExtra("transferId")
        if (event == null || event.clipData == null || event.clipData.itemCount != 1) {
            previewId?.let { AndropConnection.cancel(it) }
            Toast.makeText(this, "Drop one item at a time", Toast.LENGTH_SHORT).show(); finish(); return
        }
        permission = requestDragAndDropPermissions(event)
        edge = intent.getStringExtra("phoneEdge") ?: "LEFT"
        val item = event.clipData.getItemAt(0)
        scope.launch {
            runCatching {
                val read = withContext(Dispatchers.IO) {
                    item.uri?.let { TransferContent.read(this@EdgeDropActivity, it) }
                        ?: TransferContent.text(item.text?.toString() ?: error("Use Share → Androp for this item"))
                }
                content = read
                // The repeated ENTER hands the Mac the real name, type and picture for the same card.
                id = AndropConnection.enter(read, previewId ?: java.util.UUID.randomUUID().toString(), phoneEdge = edge)
                val picture = read.thumbnail.takeIf { it.isNotEmpty() }?.let { Base64.decode(it, Base64.DEFAULT) }
                    ?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                if (picture == null) send() else catchAtEdge(read, picture)
            }.onFailure { fail(it, id ?: previewId) }
        }
    }

    private fun catchAtEdge(read: TransferContent, picture: android.graphics.Bitmap) {
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
        window.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
        if (Build.VERSION.SDK_INT >= 28) window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        val density = resources.displayMetrics.density
        val w = 200 * density
        val h = (w * picture.height / picture.width.coerceAtLeast(1)).coerceIn(140 * density, 280 * density)
        // Anywhere but the picture keeps it on the phone.
        root = FrameLayout(this).apply { clipChildren = false; setOnClickListener { keep() } }
        card = FrameLayout(this).apply {
            elevation = 18 * density
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) = outline.setRoundRect(0, 0, view.width, view.height, 18 * density)
            }
            clipToOutline = true
            contentDescription = "${read.name}. Push it off the edge to send it to your Mac, or drag it back to keep it."
            addView(ImageView(context).apply { setImageBitmap(picture); scaleType = ImageView.ScaleType.CENTER_CROP },
                FrameLayout.LayoutParams(-1, -1))
            if (read.mime.startsWith("video/")) addView(ImageView(context).apply { setImageResource(android.R.drawable.ic_media_play) },
                FrameLayout.LayoutParams((44 * density).toInt(), (44 * density).toInt(), Gravity.CENTER))
        }
        root.addView(card, FrameLayout.LayoutParams(w.toInt(), h.toInt()))
        setContentView(root)
        root.post {
            val coordinate = intent.getFloatExtra("coordinate", 0.5f)
            // At least a third past the edge, so it plainly sits between the two screens.
            val crossed = intent.getFloatExtra("crossed", 0f).coerceIn(0.33f, 0.5f)
            val along = { size: Float, span: Int -> (coordinate * span - size / 2).coerceIn(0f, (span - size).coerceAtLeast(0f)) }
            when (edge) {
                "RIGHT" -> { caughtX = root.width - w * (1 - crossed); caughtY = along(h, root.height) }
                "TOP" -> { caughtX = along(w, root.width); caughtY = -h * crossed }
                "BOTTOM" -> { caughtX = along(w, root.width); caughtY = root.height - h * (1 - crossed) }
                else -> { caughtX = -w * crossed; caughtY = along(h, root.height) }
            }
            card.x = caughtX; card.y = caughtY
            report(force = true)
            card.setOnTouchListener(Flick(density))
            idle = scope.launch { delay(20_000); keep() }
        }
    }

    /** Share of the picture past the phone's edge: exactly what the Mac shows. */
    private fun crossed(): Float = when (edge) {
        "RIGHT" -> (card.x + card.width - root.width) / card.width
        "TOP" -> -card.y / card.height
        "BOTTOM" -> (card.y + card.height - root.height) / card.height
        else -> -card.x / card.width
    }.coerceIn(0f, 1f)

    private fun report(force: Boolean = false) {
        val now = SystemClock.uptimeMillis()
        if (!force && now - lastReport < 16) return
        lastReport = now
        val horizontal = edge == "TOP" || edge == "BOTTOM"
        val coordinate = (if (horizontal) (card.x + card.width / 2f) / root.width else (card.y + card.height / 2f) / root.height).coerceIn(0f, 1f)
        id?.let { AndropConnection.client.sendDragUpdate(DragUpdatePacket(it, coordinate, crossed(), 0f, 0f)) }
    }

    private inner class Flick(private val density: Float) : View.OnTouchListener {
        private var downX = 0f; private var downY = 0f; private var startX = 0f; private var startY = 0f
        private var tracker: VelocityTracker? = null
        override fun onTouch(view: View, event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    idle?.cancel(); view.animate().cancel()
                    downX = event.rawX; downY = event.rawY; startX = view.x; startY = view.y
                    tracker?.recycle(); tracker = VelocityTracker.obtain().apply { addMovement(event) }
                }
                MotionEvent.ACTION_MOVE -> {
                    tracker?.addMovement(event)
                    view.x = startX + event.rawX - downX; view.y = startY + event.rawY - downY
                    report()
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    tracker?.addMovement(event); tracker?.computeCurrentVelocity(1000)
                    val vx = tracker?.xVelocity ?: 0f; val vy = tracker?.yVelocity ?: 0f
                    tracker?.recycle(); tracker = null
                    val outward = when (edge) { "RIGHT" -> vx; "TOP" -> -vy; "BOTTOM" -> vy; else -> -vx } / density
                    val share = crossed()
                    when {
                        share >= 0.6f || outward > 450 -> pushAcross()
                        share <= 0.02f || outward < -450 -> keep()
                        else -> view.animate().x(caughtX).y(caughtY).setDuration(260).setInterpolator(OvershootInterpolator(1.2f))
                            .setUpdateListener { report() }.withEndAction { report(force = true); idle = scope.launch { delay(20_000); keep() } }.start()
                    }
                }
            }
            return true
        }
    }

    /** The rest of the picture slides off the phone and onto the Mac, then the original streams. */
    private fun pushAcross() {
        val (x, y) = when (edge) {
            "RIGHT" -> root.width.toFloat() to card.y
            "TOP" -> card.x to -card.height.toFloat()
            "BOTTOM" -> card.x to root.height.toFloat()
            else -> -card.width.toFloat() to card.y
        }
        card.animate().x(x).y(y).setDuration(170).setInterpolator(null).setUpdateListener { report() }
            .withEndAction { report(force = true); send() }.start()
    }

    private fun send() {
        val transfer = id ?: return
        val payload = content ?: return
        if (settled) return
        settled = true; idle?.cancel()
        // The phone is usable again while the original streams; the permissions stay with this activity.
        window.setLayout(1, 1)
        EdgeOverlayService.status.value = "Sending original to Mac"
        scope.launch {
            runCatching {
                AndropConnection.commit(transfer, payload) { sent, total, rate ->
                    EdgeOverlayService.status.value = if (total != null && total > 0) "${sent * 100 / total}% · ${android.text.format.Formatter.formatShortFileSize(this@EdgeDropActivity, rate)}/s" else "${android.text.format.Formatter.formatShortFileSize(this@EdgeDropActivity, sent)} · ${android.text.format.Formatter.formatShortFileSize(this@EdgeDropActivity, rate)}/s"
                }
            }.onSuccess { EdgeOverlayService.status.value = it; Toast.makeText(this@EdgeDropActivity, it, Toast.LENGTH_SHORT).show(); finish() }
                .onFailure { fail(it, transfer) }
        }
    }

    /** Dragged back, tapped away or left alone: nothing is sent and the Mac lets go of the card. */
    private fun keep() {
        if (settled) return
        settled = true; idle?.cancel()
        id?.let { AndropConnection.cancel(it) }
        EdgeOverlayService.status.value = "Kept on your phone"
        if (::card.isInitialized) card.animate().alpha(0f).scaleX(0.9f).scaleY(0.9f).setDuration(160).withEndAction { finish() }.start()
        else finish()
    }

    private fun fail(error: Throwable, transfer: String?) {
        settled = true
        EdgeOverlayService.status.value = error.message ?: "Transfer interrupted"
        transfer?.let { AndropConnection.cancel(it) }
        Toast.makeText(this, error.message ?: "Use Share → Androp instead", Toast.LENGTH_LONG).show()
        finish()
    }

    @Deprecated("Back keeps the item on the phone", ReplaceWith("keep()"))
    override fun onBackPressed() { keep() }

    override fun onDestroy() {
        if (!settled) id?.let { AndropConnection.cancel(it) }
        scope.cancel(); permission?.release(); super.onDestroy()
    }
}
