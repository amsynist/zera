package com.androp

import android.app.*
import android.content.*
import android.os.*
import android.view.*
import android.widget.TextView
import com.androp.gesture.EdgeGestureDetector
import com.androp.network.AndropConnection
import com.androp.overlay.EdgeOverlayService

/** No test framework dependency: run with am instrument. Requires the separate drag-source APK. */
class SmokeInstrumentation : Instrumentation() {
    private var mediaMode: String? = null
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); mediaMode = arguments?.getString("media"); start() }
    override fun onStart() {
        if (mediaMode == "seed") { MediaCapture(this).seed(); finish(Activity.RESULT_OK, Bundle()); return }
        if (mediaMode == "share") { MediaCapture(this).share(); return }
        val result = Bundle()
        try {
            val intent = Intent(targetContext, com.androp.ui.MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val activity = startActivitySync(intent)
            waitForIdleSync()
            var releases = 0
            var didCommit = false
            runOnMainSync {
                val card = activity.findViewById<View>(R.id.dragCard)
                val detector = EdgeGestureDetector(card, { "LEFT" }, object : EdgeGestureDetector.Listener {
                    override fun onDragEnter(edge: String) = Unit
                    override fun onDragUpdate(normalizedY: Float, crossRatio: Float, velocityX: Float, velocityY: Float) = Unit
                    override fun onDragRelease(committed: Boolean, velocityX: Float, velocityY: Float) { releases++; didCommit = committed }
                })
                val t = SystemClock.uptimeMillis()
                val events = listOf(
                    MotionEvent.obtain(t, t, MotionEvent.ACTION_DOWN, 500f, 650f, 0),
                    MotionEvent.obtain(t, t + 100, MotionEvent.ACTION_MOVE, 0f, 650f, 0),
                    MotionEvent.obtain(t, t + 110, MotionEvent.ACTION_CANCEL, 0f, 650f, 0))
                events.forEach { detector.onTouch(card, it); it.recycle() }
                check(releases == 1 && !didCommit) { "Cancelled gesture committed a transfer" }
                releases = 0
                val returnToCenter = listOf(
                    MotionEvent.obtain(t + 500, t + 500, MotionEvent.ACTION_DOWN, 500f, 650f, 0),
                    MotionEvent.obtain(t + 500, t + 600, MotionEvent.ACTION_MOVE, 0f, 650f, 0),
                    MotionEvent.obtain(t + 500, t + 700, MotionEvent.ACTION_MOVE, 500f, 650f, 0),
                    MotionEvent.obtain(t + 500, t + 710, MotionEvent.ACTION_UP, 500f, 650f, 0))
                returnToCenter.forEach { detector.onTouch(card, it); it.recycle() }
                check(releases == 1 && !didCommit) { "Returning from the edge failed to retract" }
                targetContext.startForegroundService(Intent(targetContext, EdgeOverlayService::class.java))
            }
            val deadline = SystemClock.uptimeMillis() + 15_000
            while (!AndropConnection.isConnected && SystemClock.uptimeMillis() < deadline) Thread.sleep(100)
            check(AndropConnection.isConnected) { "Test Mac receiver not connected" }
            Thread.sleep(500)
            uiAutomation.takeScreenshot()?.let { bitmap ->
                java.io.File(targetContext.filesDir, "home-smoke.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
            for (edge in listOf("LEFT", "RIGHT", "TOP", "BOTTOM")) {
                fixture(edge)
                dragToEdge(650f, edge)
                Thread.sleep(1800)
                check(!com.androp.overlay.EdgeOverlayService.status.value.contains("failed", true))
            }
            fixture("RIGHT", large = true)
            dragToEdge(650f, "RIGHT")
            val droppedAt = SystemClock.elapsedRealtime()
            val largeDeadline = SystemClock.uptimeMillis() + 120_000
            while (com.androp.overlay.EdgeOverlayService.status.value != "Saved on your Mac" && SystemClock.uptimeMillis() < largeDeadline) Thread.sleep(100)
            check(com.androp.overlay.EdgeOverlayService.status.value == "Saved on your Mac") { "Large stream failed: ${com.androp.overlay.EdgeOverlayService.status.value}" }
            val transferSeconds = (SystemClock.elapsedRealtime() - droppedAt) / 1000.0
            result.putDouble("large_drop_to_save_seconds", transferSeconds)
            fixture("BOTTOM")
            dragToEdge(1070f, "BOTTOM")
            Thread.sleep(1800)
            result.putString("stream", "Cancellation passed. Four edge image drops, one 100 MiB URI stream, and a text drop injected from a separate UID; verify the Mac test inbox.\n")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("stream", "FAILED: ${error.stackTraceToString()}\n")
            finish(Activity.RESULT_CANCELED, result)
        }
    }
    private fun fixture(edge: String, large: Boolean = false) {
        targetContext.startActivity(Intent().setClassName("com.androp.fixture", "com.androp.fixture.DragSourceActivity")
            .putExtra("edge", edge).putExtra("large", large)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        Thread.sleep(if (large) 2400 else 900)
    }
    private fun dragToEdge(y: Float, edge: String) {
        val t = SystemClock.uptimeMillis()
        val x = targetContext.resources.displayMetrics.widthPixels / 2f
        val height = targetContext.resources.displayMetrics.heightPixels
        val targetX = when (edge) { "LEFT" -> 60f; "RIGHT" -> x * 2 - 60f; else -> x }
        val targetY = when (edge) { "TOP" -> 150f; "BOTTOM" -> height - 150f; else -> y }
        fun event(action: Int, px: Float, py: Float) {
            val event = MotionEvent.obtain(t, SystemClock.uptimeMillis(), action, px, py, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            check(uiAutomation.injectInputEvent(event, true)) { "Could not inject test drag" }; event.recycle()
        }
        event(MotionEvent.ACTION_DOWN, x, y)
        Thread.sleep(750)
        for (step in 1..35) { event(MotionEvent.ACTION_MOVE, x + (targetX - x) * step / 35, y + (targetY - y) * step / 35); Thread.sleep(20) }
        event(MotionEvent.ACTION_UP, targetX, targetY)
    }
}
