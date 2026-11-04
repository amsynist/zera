package com.androp.gesture

import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.abs

class EdgeGestureDetector(private val targetView: View, private val edge: () -> String, private val listener: Listener) : View.OnTouchListener {
    interface Listener {
        fun onDragEnter(edge: String)
        fun onDragUpdate(normalizedY: Float, crossRatio: Float, velocityX: Float, velocityY: Float)
        fun onDragRelease(committed: Boolean, velocityX: Float, velocityY: Float)
    }
    private var startX = 0f
    private var startY = 0f
    private var tracker: VelocityTracker? = null
    private var crossing: String? = null
    private var dragging = false
    private val slop = ViewConfiguration.get(targetView.context).scaledTouchSlop

    override fun onTouch(v: View, event: MotionEvent): Boolean {
        val root = v.rootView
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                v.animate().cancel()
                v.translationX = 0f; v.translationY = 0f
                startX = event.rawX; startY = event.rawY
                tracker?.recycle()
                tracker = VelocityTracker.obtain().apply { addMovement(event) }
                crossing = null; dragging = false
                v.parent.requestDisallowInterceptTouchEvent(true)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                tracker?.addMovement(event)
                val dx = event.rawX - startX
                val dy = event.rawY - startY
                if (!dragging && abs(dx) + abs(dy) < slop) return true
                dragging = true
                v.translationX = dx; v.translationY = dy
                v.rotation = (dx / root.width * 4).coerceIn(-4f, 4f)
                val location = IntArray(2); v.getLocationOnScreen(location)
                val gaps = mapOf("LEFT" to location[0], "RIGHT" to root.width - location[0] - v.width,
                    "TOP" to location[1], "BOTTOM" to root.height - location[1] - v.height)
                val directions = setOfNotNull(if (dx < -slop) "LEFT" else if (dx > slop) "RIGHT" else null,
                    if (dy < -slop) "TOP" else if (dy > slop) "BOTTOM" else null)
                val selected = if (edge() == "AUTO") gaps.filterKeys { it in directions }.minByOrNull { it.value }?.key else edge()
                val threshold = 72 * v.resources.displayMetrics.density
                val gap = gaps[selected]?.toFloat() ?: Float.MAX_VALUE
                if (selected != null && gap < threshold) {
                    if (crossing != selected) {
                        if (crossing != null) listener.onDragRelease(false, 0f, 0f)
                        crossing = selected
                        listener.onDragEnter(selected)
                    }
                    tracker?.computeCurrentVelocity(1000)
                    val horizontal = selected == "TOP" || selected == "BOTTOM"
                    // Only the part of the card already past the phone's edge, so the Mac shows exactly that much.
                    listener.onDragUpdate((if (horizontal) event.rawX / root.width else event.rawY / root.height).coerceIn(0f, 1f),
                        (-gap / (if (horizontal) v.height else v.width)).coerceIn(0f, 1f), tracker?.xVelocity ?: 0f, tracker?.yVelocity ?: 0f)
                } else if (crossing != null) {
                    listener.onDragRelease(false, 0f, 0f)
                    crossing = null
                }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                tracker?.addMovement(event); tracker?.computeCurrentVelocity(1000)
                val vx = tracker?.xVelocity ?: 0f; val vy = tracker?.yVelocity ?: 0f
                val location = IntArray(2); v.getLocationOnScreen(location)
                val crossed = when (crossing) {
                    "RIGHT" -> location[0] + v.width > root.width
                    "TOP" -> location[1] < 0
                    "BOTTOM" -> location[1] + v.height > root.height
                    else -> location[0] < 0
                }
                val fling = when (crossing) { "RIGHT" -> vx > 700; "TOP" -> vy < -700; "BOTTOM" -> vy > 700; else -> vx < -700 }
                if (crossing != null) listener.onDragRelease(event.actionMasked == MotionEvent.ACTION_UP && (crossed || fling), vx, vy)
                if (!dragging && event.actionMasked == MotionEvent.ACTION_UP) v.performClick()
                v.animate().translationX(0f).translationY(0f).rotation(0f).setDuration(360).start()
                tracker?.recycle(); tracker = null; crossing = null
                v.parent.requestDisallowInterceptTouchEvent(false)
                return true
            }
        }
        return false
    }
}
