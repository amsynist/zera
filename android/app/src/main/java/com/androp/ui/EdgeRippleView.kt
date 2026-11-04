package com.androp.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.*
import android.provider.Settings
import android.util.AttributeSet
import android.view.View
import android.view.animation.LinearInterpolator
import kotlin.math.sin

/**
 * The phone's half of the crossing, matching the Mac's arrival ripple: while a file is dragged into an
 * edge, rings pulse from the point where it meets the edge and the seam brightens and lengthens as
 * more of it crosses. Renders only during an interaction; no vibration.
 */
class EdgeRippleView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    var edge = "LEFT"
    private var coordinate = 0.5f
    private var crossed = 0f
    private var progress = 0f
    private var strength = 0f
    private var pulse = 0f
    private var releasing = false
    private var animator: ValueAnimator? = null
    private var pulsing: ValueAnimator? = null
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val reduced get() = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    fun approach(coordinate: Float) {
        this.coordinate = coordinate.coerceIn(0.05f, 0.95f)
        animator?.cancel()
        releasing = false
        strength = 0.85f
        if (pulsing == null && !reduced) pulsing = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1400; repeatCount = ValueAnimator.INFINITE; interpolator = LinearInterpolator()
            addUpdateListener { pulse = it.animatedValue as Float; invalidate() }
            start()
        }
        invalidate()
    }

    /** How much of the file is past the edge, 0…1: the glow and seam grow with it. */
    fun cross(ratio: Float) { crossed = ratio.coerceIn(0f, 1f); invalidate() }

    fun release(committed: Boolean) {
        pulsing?.cancel(); pulsing = null
        animator?.cancel()
        if (reduced) { strength = 0f; crossed = 0f; invalidate(); return }
        releasing = true
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = if (committed) 1050 else 220
            addUpdateListener {
                progress = it.animatedValue as Float
                strength = 1f - progress
                if (progress >= 1f) { crossed = 0f; releasing = false }
                invalidate()
            }
            start()
        }
    }

    override fun onDraw(canvas: Canvas) {
        if (strength <= 0f) return
        val d = resources.displayMetrics.density
        if (edge == "AUTO") {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 2 * d
            paint.shader = LinearGradient(0f, 0f, width.toFloat(), height.toFloat(),
                intArrayOf(Color.argb((150 * strength).toInt(), 140, 238, 225), Color.argb((180 * strength).toInt(), 173, 151, 245)), null, Shader.TileMode.CLAMP)
            canvas.drawRoundRect(d, d, width - d, height - d, 16 * d, 16 * d, paint)
            paint.shader = null
            return
        }
        val horizontal = edge == "TOP" || edge == "BOTTOM"
        val x = if (horizontal) width * coordinate else if (edge == "RIGHT") width.toFloat() else 0f
        val y = if (edge == "BOTTOM") height.toFloat() else if (edge == "TOP") 0f else height * coordinate
        // The aura where the file meets the edge, swelling as it crosses.
        val aura = (130 + 120 * crossed) * d
        paint.style = Paint.Style.FILL
        paint.shader = RadialGradient(x, y, aura, intArrayOf(Color.argb(((55 + 90 * crossed) * strength).toInt(), 172, 239, 223),
            Color.argb(((25 + 40 * crossed) * strength).toInt(), 173, 151, 245), Color.TRANSPARENT), floatArrayOf(0f, 0.45f, 1f), Shader.TileMode.CLAMP)
        canvas.drawCircle(x, y, aura, paint)
        paint.shader = null
        // Rings: pulsing while it is held at the edge, one wide burst on release.
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1.4f * d
        repeat(3) {
            val phase = if (releasing) (progress - it * 0.1f).coerceIn(0f, 1f) else (pulse + it / 3f) % 1f
            val reach = if (releasing) 400f else 120f + 140f * crossed
            paint.color = Color.argb((sin(phase * Math.PI) * 110 * strength).toInt().coerceIn(0, 255), 188, 236, 232)
            canvas.drawCircle(x, y, (18 + phase * reach) * d, paint)
        }
        // The seam: a bright line along the edge, longer and stronger the further the file has crossed.
        val half = (80 + 160 * crossed) * d
        paint.style = Paint.Style.FILL
        paint.shader = LinearGradient(if (horizontal) x - half else x, if (horizontal) y else y - half,
            if (horizontal) x + half else x, if (horizontal) y else y + half,
            intArrayOf(Color.TRANSPARENT, Color.argb((235 * strength).toInt(), 205, 255, 241), Color.argb((200 * strength).toInt(), 190, 170, 255), Color.TRANSPARENT),
            floatArrayOf(0f, 0.45f, 0.55f, 1f), Shader.TileMode.CLAMP)
        val thick = (1.2f + 2.2f * crossed) * d
        if (horizontal) canvas.drawRoundRect(x - half, y - thick, x + half, y + thick, thick, thick, paint)
        else canvas.drawRoundRect(x - thick, y - half, x + thick, y + half, thick, thick, paint)
        paint.shader = null
    }
    override fun onDetachedFromWindow() { animator?.cancel(); pulsing?.cancel(); pulsing = null; super.onDetachedFromWindow() }
}
