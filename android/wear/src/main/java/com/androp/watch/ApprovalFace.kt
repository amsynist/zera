package com.androp.watch

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.RectF
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.text.TextPaint
import android.text.TextUtils
import android.util.TypedValue
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sin

/**
 * Minimal round Signal face. Black, one status dot, Zera's eyes, the action. The request itself
 * is the control: drag it right to approve or left to deny while that edge of the screen fills.
 * Only three moments move: the request rising in, the drag, and the result mark being drawn.
 */
internal class ApprovalFace(context: Context) : View(context) {
    enum class Control { None, Slide, Tap }
    enum class Ring { Idle, Waiting, Busy, Approved, Denied }

    /** Small line under the action (project, or a count). */
    var caption = ""
    /** Dim word above the action, such as the tool. */
    var verb = ""
    /** The action itself, large. */
    var target = ""
    var hint = ""
    /** Small text under the content for Tap states; empty draws the phone mark instead. */
    var tapLabel = ""
    var control = Control.None
    var ring = Ring.Idle
        set(value) {
            if (field != value && (value == Ring.Approved || value == Ring.Denied)) resultStart = SystemClock.uptimeMillis()
            field = value
        }
    var happy = false

    var onApprove: (() -> Unit)? = null
    var onDeny: (() -> Unit)? = null
    var onTap: (() -> Unit)? = null

    private val mono = resources.getFont(R.font.signal_mono)
    private val ink = context.getColor(R.color.signal_text)
    private val accent = context.getColor(R.color.signal_accent)
    private val amber = context.getColor(R.color.signal_warning)
    private val danger = context.getColor(R.color.signal_danger)
    private val dim = Color.rgb(111, 130, 144)
    private val faint = Color.rgb(58, 72, 82)

    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; typeface = mono }
    private val rect = RectF()
    private val mark = Path()
    private val partial = Path()
    private val measure = PathMeasure()
    private val slop = ViewConfiguration.get(context).scaledTouchSlop

    private var enterStart = 0L
    private var resultStart = 0L
    private var drag = 0f
    private var dragging = false
    private var tracking = false
    private var downX = 0f
    private var downY = 0f
    private var grabDrag = 0f
    private var committed = false
    private var armed = false
    private var settle: ValueAnimator? = null

    init {
        isFocusable = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    /** Reduce Motion: an animator scale of 0 drops every transition. Dragging still tracks the finger. */
    private val motion: Boolean
        get() = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f

    fun update() {
        contentDescription = listOf(verb, target, caption, hint).filter(String::isNotBlank).joinToString(". ")
        if (control != Control.Slide) { settle?.cancel(); drag = 0f }
        committed = false
        armed = false
        invalidate()
    }

    /** A new request: rise into place. */
    fun enter() {
        settle?.cancel()
        drag = 0f
        enterStart = if (motion) SystemClock.uptimeMillis() else 0L
        invalidate()
    }

    private fun dp(v: Float) = v * resources.displayMetrics.density
    private fun sp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v, resources.displayMetrics)
    private val cx get() = width / 2f
    private val cy get() = height / 2f
    private val radius get() = min(width, height) / 2f
    private val reach get() = radius * .72f
    private val fraction get() = if (reach > 0) (drag / reach).coerceIn(-1f, 1f) else 0f

    override fun onDraw(canvas: Canvas) {
        val now = SystemClock.uptimeMillis()
        var animating = false
        canvas.drawColor(Color.BLACK)

        if (ring == Ring.Approved || ring == Ring.Denied) {
            animating = drawResult(canvas, now)
            if (animating && isShown) postInvalidateOnAnimation()
            return
        }

        val f = fraction
        // The edge the request is heading for fills along the bezel.
        if (control == Control.Slide && abs(f) > .02f) {
            val r = radius - dp(4f)
            rect.set(cx - r, cy - r, cx + r, cy + r)
            stroke.strokeWidth = dp(4f)
            stroke.color = if (f > 0) accent else danger
            stroke.alpha = (110 + 145 * abs(f)).toInt()
            val sweep = 170f * abs(f)
            canvas.drawArc(rect, (if (f > 0) 0f else 180f) - sweep / 2f, sweep, false, stroke)
            stroke.alpha = 255
            text.textSize = sp(13f)
            text.color = if (f > 0) accent else danger
            text.alpha = (255 * ((abs(f) - .15f) / .6f).coerceIn(0f, 1f)).toInt()
            canvas.drawText(if (f > 0) "Approve" else "Deny", cx - (if (f > 0) 1 else -1) * radius * .42f, cy + sp(5f), text)
        }

        // Status dot: amber while waiting, a soft mint pulse while the Mac decides.
        val dotY = cy - radius + dp(10f)
        when (ring) {
            Ring.Waiting -> { fill.color = amber; fill.alpha = 255; canvas.drawCircle(cx, dotY, dp(3f), fill) }
            Ring.Busy -> {
                val pulse = if (motion) { animating = true; (sin(now / 900.0 * Math.PI).toFloat() + 1f) / 2f } else 1f
                fill.color = accent; fill.alpha = (90 + 165 * pulse).toInt()
                canvas.drawCircle(cx, dotY, dp(3f), fill)
            }
            else -> Unit
        }
        fill.alpha = 255

        // The request rises in, then follows the finger and dims as it leaves the center.
        val rise = if (enterStart == 0L) 1f else ((now - enterStart) / 380f).coerceIn(0f, 1f)
        if (rise < 1f) animating = true
        val eased = 1f - (1f - rise) * (1f - rise) * (1f - rise)
        val alpha = (255 * eased * (1f - .5f * abs(f))).toInt()
        val save = canvas.save()
        canvas.translate(drag, (1f - eased) * radius * .3f)

        drawEyes(canvas, cy - radius * .48f, alpha)
        val width = radius * 1.45f
        // Short actions sit on one large line; longer ones wrap onto up to four smaller lines.
        text.textSize = sp(20f)
        val single = target.isEmpty() || text.measureText(target) <= width
        val size = if (single) 20f else 14f
        text.textSize = sp(size)
        val lines = if (single) listOf(target) else wrap(target, width * .94f, 4)
        val step = sp(size) * 1.28f
        val top = cy + sp(6f) - step * (lines.size - 1) / 2f
        if (verb.isNotEmpty()) line(canvas, verb, top - sp(if (single) 24f else 20f), 12f, dim, width, alpha)
        lines.forEachIndexed { i, value -> line(canvas, value, top + step * i, size, ink, width, alpha) }
        line(canvas, caption, top + step * (lines.size - 1) + sp(22f), 11f, dim, width, alpha)
        canvas.restoreToCount(save)

        val below = cy + radius * .68f
        when (control) {
            Control.Slide -> {
                val a = (255 * eased * (1f - abs(f) * 6f).coerceIn(0f, 1f)).toInt()
                line(canvas, "‹      ›", below, 13f, faint, width, a)
            }
            Control.Tap -> if (tapLabel.isEmpty()) drawPhone(canvas, below, alpha) else line(canvas, tapLabel, below, 11f, accent, width, alpha)
            Control.None -> Unit
        }
        if (hint.isNotEmpty()) line(canvas, hint, cy + radius * .84f, 10f, faint, radius * .9f, alpha)

        if (animating && isShown) postInvalidateOnAnimation()
    }

    private fun drawEyes(canvas: Canvas, y: Float, alpha: Int) {
        fill.color = accent; fill.alpha = alpha
        val lean = fraction * dp(3f)
        for (x in listOf(cx - dp(9f), cx + dp(9f))) {
            rect.set(x + lean - dp(2.5f), y - dp(4.5f), x + lean + dp(2.5f), y + dp(4.5f))
            canvas.drawRoundRect(rect, dp(2f), dp(2f), fill)
        }
        fill.alpha = 255
    }

    private fun drawPhone(canvas: Canvas, y: Float, alpha: Int) {
        stroke.color = accent; stroke.alpha = alpha; stroke.strokeWidth = dp(1.5f)
        rect.set(cx - dp(7f), y - dp(14f), cx + dp(7f), y + dp(8f))
        canvas.drawRoundRect(rect, dp(3f), dp(3f), stroke)
        stroke.alpha = 255
    }

    /** One stroke, drawn once: a check for approved, a cross for denied. */
    private fun drawResult(canvas: Canvas, now: Long): Boolean {
        val approved = ring == Ring.Approved
        val p = if (motion) ((now - resultStart) / 340f).coerceIn(0f, 1f) else 1f
        val s = radius * .2f
        mark.reset()
        if (approved) {
            mark.moveTo(cx - s * 1.05f, cy - s * .05f)
            mark.lineTo(cx - s * .3f, cy + s * .7f)
            mark.lineTo(cx + s * 1.1f, cy - s * .75f)
        } else {
            mark.moveTo(cx - s * .7f, cy - s * .7f); mark.lineTo(cx + s * .7f, cy + s * .7f)
            mark.moveTo(cx + s * .7f, cy - s * .7f); mark.lineTo(cx - s * .7f, cy + s * .7f)
        }
        stroke.color = if (approved) accent else danger
        stroke.strokeWidth = dp(5f)
        partial.reset()
        measure.setPath(mark, false)
        var total = 0f
        do total += measure.length while (measure.nextContour())
        var budget = total * (1f - (1f - p) * (1f - p))
        measure.setPath(mark, false)
        do {
            val len = measure.length
            measure.getSegment(0f, min(len, budget), partial, true)
            budget -= len
        } while (budget > 0f && measure.nextContour())
        canvas.drawPath(partial, stroke)
        val labelAlpha = (255 * ((p - .4f) / .6f).coerceIn(0f, 1f)).toInt()
        line(canvas, verb, cy + radius * .5f, 12f, dim, radius * 1.4f, labelAlpha)
        return p < 1f
    }

    /** Greedy wrap for the current text size, preferring breaks after spaces and slashes. */
    private fun wrap(value: String, width: Float, maxLines: Int): List<String> {
        val out = mutableListOf<String>()
        var rest = value.trim()
        while (rest.isNotEmpty() && out.size < maxLines) {
            var fit = text.breakText(rest, true, width, null).coerceAtLeast(1)
            if (fit < rest.length) {
                val cut = rest.substring(0, fit).indexOfLast { it == ' ' || it == '/' }
                if (cut > fit / 3) fit = cut + 1
            }
            var piece = rest.substring(0, fit).trimEnd()
            rest = rest.substring(fit).trimStart()
            if (out.size == maxLines - 1 && rest.isNotEmpty()) {
                piece = TextUtils.ellipsize("$piece $rest", text, width, TextUtils.TruncateAt.END).toString()
                rest = ""
            }
            out += piece
        }
        return out
    }

    private fun line(canvas: Canvas, value: String, y: Float, size: Float, color: Int, width: Float, alpha: Int) {
        if (value.isEmpty() || alpha <= 0) return
        text.color = color
        text.alpha = alpha
        text.textSize = sp(size)
        while (text.measureText(value) > width && text.textSize > sp(11f)) text.textSize -= sp(.5f)
        canvas.drawText(TextUtils.ellipsize(value, text, width, TextUtils.TruncateAt.MIDDLE).toString(), cx, y, text)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x; downY = event.y
                tracking = true
                dragging = false
                if (control == Control.Slide && !committed) { settle?.cancel(); grabDrag = drag }
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (!tracking) return true
                val dx = event.x - downX
                val dy = event.y - downY
                if (!dragging && control == Control.Slide && !committed && abs(dx) > slop && abs(dx) > abs(dy)) {
                    dragging = true
                    parent?.requestDisallowInterceptTouchEvent(true)
                }
                if (dragging) {
                    drag = (grabDrag + dx).coerceIn(-reach, reach)
                    val now = abs(fraction) >= COMMIT
                    if (now && !armed) performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    armed = now
                    invalidate()
                }
            }
            MotionEvent.ACTION_UP -> {
                tracking = false
                if (dragging) { dragging = false; release() }
                else if (control == Control.Tap && abs(event.x - downX) < slop && abs(event.y - downY) < slop) {
                    performClick(); onTap?.invoke()
                }
            }
            MotionEvent.ACTION_CANCEL -> { tracking = false; if (dragging) { dragging = false; springBack() } }
        }
        return true
    }

    override fun performClick(): Boolean = super.performClick()

    private fun release() {
        val f = fraction
        if (abs(f) < COMMIT) { springBack(); return }
        committed = true
        val approve = f > 0
        performHapticFeedback(if (approve) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.REJECT)
        animateDrag(if (approve) reach else -reach, 120L, DecelerateInterpolator()) {
            if (approve) onApprove?.invoke() else onDeny?.invoke()
        }
    }

    private fun springBack() = animateDrag(0f, 300L, OvershootInterpolator(1.4f), null)

    private fun animateDrag(to: Float, duration: Long, interpolator: android.animation.TimeInterpolator, done: (() -> Unit)?) {
        settle?.cancel()
        if (!motion) { drag = to; armed = false; invalidate(); done?.invoke(); return }
        settle = ValueAnimator.ofFloat(drag, to).apply {
            this.duration = duration
            this.interpolator = interpolator
            addUpdateListener { drag = it.animatedValue as Float; invalidate() }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                private var cancelled = false
                override fun onAnimationCancel(animation: android.animation.Animator) { cancelled = true }
                override fun onAnimationEnd(animation: android.animation.Animator) { armed = false; if (!cancelled) done?.invoke() }
            })
            start()
        }
    }

    override fun onDetachedFromWindow() { settle?.cancel(); super.onDetachedFromWindow() }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        if (control == Control.Slide) {
            info.addAction(AccessibilityNodeInfo.AccessibilityAction(R.id.zerax_approve, "Approve once"))
            info.addAction(AccessibilityNodeInfo.AccessibilityAction(R.id.zerax_deny, "Deny"))
        } else if (control == Control.Tap) {
            info.addAction(AccessibilityNodeInfo.AccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, tapLabel.ifEmpty { "Open on phone" }))
        }
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean = when {
        control == Control.Slide && action == R.id.zerax_approve -> { onApprove?.invoke(); true }
        control == Control.Slide && action == R.id.zerax_deny -> { onDeny?.invoke(); true }
        control == Control.Tap && action == AccessibilityNodeInfo.ACTION_CLICK -> { onTap?.invoke(); true }
        else -> super.performAccessibilityAction(action, arguments)
    }

    private companion object { const val COMMIT = .8f }
}
