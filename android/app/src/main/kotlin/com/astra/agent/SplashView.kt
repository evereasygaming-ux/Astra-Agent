package com.astra.agent

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator

class SplashView(context: Context) : View(context) {
    private val density = resources.displayMetrics.density
    private val artwork: Bitmap? = BitmapFactory.decodeResource(
        resources,
        R.drawable.astra_code_launch,
        BitmapFactory.Options().apply { inScaled = false },
    )
    private val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val outerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xF2050818.toInt()
    }
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density
        color = CYAN
    }
    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF0A1021.toInt()
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 13f * resources.displayMetrics.scaledDensity
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textAlign = Paint.Align.CENTER
    }
    private val outerRect = RectF()
    private val trackRect = RectF()
    private var progress = 0f
    private var animator: ValueAnimator? = null

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun start() {
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1600L
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener {
                progress = it.animatedValue as Float
                invalidate()
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    postDelayed({ fadeOut() }, 600L)
                }
            })
            start()
        }
    }

    fun stop() {
        animator?.cancel()
        animator = null
    }

    private fun fadeOut() {
        animate().alpha(0f).setDuration(300L).withEndAction {
            (parent as? android.view.ViewGroup)?.removeView(this)
        }.start()
    }

    override fun onDetachedFromWindow() {
        stop()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val bitmap = artwork
        if (bitmap == null || bitmap.width == 0 || bitmap.height == 0 || w == 0f || h == 0f) {
            return
        }

        val scale = maxOf(w / bitmap.width, h / bitmap.height)
        val dx = (w - bitmap.width * scale) / 2f
        val dy = (h - bitmap.height * scale) / 2f
        canvas.save()
        canvas.clipRect(0f, 0f, w, h)
        canvas.drawBitmap(
            bitmap,
            null,
            RectF(dx, dy, dx + bitmap.width * scale, dy + bitmap.height * scale),
            bitmapPaint,
        )
        canvas.restore()

        val barLeft = dx + 112f * scale
        val barTop = dy + 1032f * scale
        val barWidth = 718f * scale
        val barHeight = (70f * scale).coerceIn(38f * density, 70f * density)
        outerRect.set(barLeft, barTop, barLeft + barWidth, barTop + barHeight)
        val outerRadius = minOf(28f * density, barHeight / 2f)
        canvas.drawRoundRect(outerRect, outerRadius, outerRadius, outerPaint)
        canvas.drawRoundRect(outerRect, outerRadius, outerRadius, borderPaint)

        val padH = 7f * density
        val padV = 4f * density
        val textWidth = 45f * density
        val gap = 10f * density
        val innerRadius = 12f * density
        trackRect.set(
            outerRect.left + padH,
            outerRect.top + padV,
            outerRect.right - padH - textWidth - gap,
            outerRect.bottom - padV,
        )
        canvas.drawRoundRect(trackRect, innerRadius, innerRadius, trackPaint)

        if (progress > 0f) {
            val save = canvas.save()
            canvas.clipRect(
                trackRect.left,
                trackRect.top,
                trackRect.left + trackRect.width() * progress,
                trackRect.bottom,
            )
            fillPaint.shader = LinearGradient(
                trackRect.left,
                trackRect.top,
                trackRect.right,
                trackRect.top,
                intArrayOf(ACCENT, ACCENT_ALT, CYAN),
                null,
                Shader.TileMode.CLAMP,
            )
            canvas.drawRoundRect(trackRect, innerRadius, innerRadius, fillPaint)
            fillPaint.shader = null
            canvas.restoreToCount(save)
        }

        val percent = (progress * 100).toInt()
        val textCenterX = trackRect.right + gap + textWidth / 2f
        val baseline = outerRect.centerY() -
            (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText("$percent%", textCenterX, baseline, textPaint)
    }

    companion object {
        private val ACCENT = 0xFFF12DFF.toInt()
        private val ACCENT_ALT = 0xFF586BFF.toInt()
        private val CYAN = 0xFF20DFFF.toInt()
    }
}
