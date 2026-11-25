package ren.onekb.openuu

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.PointF
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Display
import kotlin.math.hypot

/**
 * Translates normalized [0..1] pointer & scroll coordinates from an authorized OpenUU client
 * into Android [GestureDescription] strokes on the main looper (supporting both default display
 * and API 30+ virtual `displayId`s).
 */
class RemoteTouchDispatcher(
    private val service: AccessibilityService,
    private val targetDisplayId: Int = Display.DEFAULT_DISPLAY,
    private val displayBoundsProvider: () -> Pair<Int, Int>
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun buildGestureWithStroke(stroke: GestureDescription.StrokeDescription): GestureDescription {
        val builder = GestureDescription.Builder().addStroke(stroke)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && targetDisplayId != Display.DEFAULT_DISPLAY) {
            runCatching { builder.setDisplayId(targetDisplayId) }
        }
        return builder.build()
    }

    private var pointerDown = false
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var strokeAnchorX = 0f
    private var strokeAnchorY = 0f
    private var downTimeMs = 0L

    private var activeStroke: GestureDescription.StrokeDescription? = null
    private var strokeInFlight = false
    private var pendingMove: PointF? = null
    private var pendingUp: PointF? = null

    private var scrollInFlight = false
    private var accumScrollDx = 0f
    private var accumScrollDy = 0f
    private var lastScrollX = 0f
    private var lastScrollY = 0f

    private val holdStartRunnable = object : Runnable {
        override fun run() {
            if (!pointerDown || activeStroke != null || strokeInFlight) return
            beginContinuedStroke(downX, downY, lastX, lastY, durationMs = 110L)
        }
    }

    fun handlePointer(
        normX: Float,
        normY: Float,
        eventType: Int,
        button: Int
    ) {
        mainHandler.post {
            val (w, h) = displayBoundsProvider()
            if (w <= 2 || h <= 2) return@post
            val sx = (normX.coerceIn(0f, 1f) * w).coerceIn(1f, (w - 2).toFloat())
            val sy = (normY.coerceIn(0f, 1f) * h).coerceIn(1f, (h - 2).toFloat())

            if (button == 1) {
                if (eventType == 1) {
                    service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
                }
                return@post
            }
            if (button == 2) {
                if (eventType == 1) {
                    service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME)
                }
                return@post
            }

            when (eventType) {
                1 -> onLeftDown(sx, sy)
                3 -> onLeftDrag(sx, sy)
                2 -> onLeftUp(sx, sy)
            }
        }
    }

    fun handleScroll(
        normX: Float,
        normY: Float,
        deltaX: Float,
        deltaY: Float,
        isContinuous: Boolean
    ) {
        mainHandler.post {
            if (pointerDown || strokeInFlight) return@post
            val (w, h) = displayBoundsProvider()
            if (w <= 2 || h <= 2) return@post
            val sx = (normX.coerceIn(0f, 1f) * w).coerceIn(16f, (w - 16).toFloat())
            val sy = (normY.coerceIn(0f, 1f) * h).coerceIn(16f, (h - 16).toFloat())

            val scale = if (isContinuous) 2.4f else 56f
            accumScrollDx += deltaX * scale
            accumScrollDy += deltaY * scale
            lastScrollX = sx
            lastScrollY = sy

            if (!scrollInFlight) {
                flushScrollLocked(w, h)
            }
        }
    }

    private fun onLeftDown(sx: Float, sy: Float) {
        mainHandler.removeCallbacks(holdStartRunnable)
        pointerDown = true
        downX = sx
        downY = sy
        lastX = sx
        lastY = sy
        downTimeMs = SystemClock.uptimeMillis()
        pendingMove = null
        pendingUp = null
        activeStroke = null
        mainHandler.postDelayed(holdStartRunnable, 135L)
    }

    private fun onLeftDrag(sx: Float, sy: Float) {
        if (!pointerDown) return
        lastX = sx
        lastY = sy
        val dist = hypot(sx - downX, sy - downY)
        if (activeStroke == null && !strokeInFlight) {
            if (dist >= 8f || SystemClock.uptimeMillis() - downTimeMs >= 80L) {
                mainHandler.removeCallbacks(holdStartRunnable)
                beginContinuedStroke(downX, downY, sx, sy, durationMs = 45L)
            }
        } else {
            pendingMove = PointF(sx, sy)
            if (!strokeInFlight) {
                pumpContinuedStroke()
            }
        }
    }

    private fun onLeftUp(sx: Float, sy: Float) {
        mainHandler.removeCallbacks(holdStartRunnable)
        if (!pointerDown && activeStroke == null) return
        pointerDown = false
        lastX = sx
        lastY = sy

        if (activeStroke == null && !strokeInFlight) {
            val moved = hypot(sx - downX, sy - downY) > 8f
            val path = Path().apply {
                moveTo(downX, downY)
                if (moved) lineTo(sx, sy)
            }
            val stroke = GestureDescription.StrokeDescription(path, 0L, if (moved) 65L else 38L, false)
            val gesture = buildGestureWithStroke(stroke)
            runCatching { service.dispatchGesture(gesture, null, mainHandler) }
            return
        }

        pendingUp = PointF(sx, sy)
        if (!strokeInFlight) {
            pumpContinuedStroke()
        }
    }

    private fun beginContinuedStroke(x0: Float, y0: Float, x1: Float, y1: Float, durationMs: Long) {
        val path = Path().apply {
            moveTo(x0, y0)
            lineTo(x1, y1)
        }
        val stroke = runCatching {
            GestureDescription.StrokeDescription(path, 0L, durationMs, true)
        }.getOrNull() ?: return
        val gesture = buildGestureWithStroke(stroke)

        strokeAnchorX = x1
        strokeAnchorY = y1
        activeStroke = stroke
        strokeInFlight = true

        val ok = runCatching {
            service.dispatchGesture(gesture, strokeCallback, mainHandler)
        }.getOrDefault(false)
        if (!ok) {
            resetStrokeState()
        }
    }

    private fun pumpContinuedStroke() {
        val current = activeStroke ?: return
        if (strokeInFlight) return

        val upTarget = pendingUp
        if (upTarget != null) {
            pendingUp = null
            pendingMove = null
            val path = Path().apply {
                moveTo(strokeAnchorX, strokeAnchorY)
                lineTo(upTarget.x, upTarget.y)
            }
            val fin = runCatching {
                current.continueStroke(path, 0L, 28L, false)
            }.getOrNull()
            resetStrokeState()
            if (fin != null) {
                val g = buildGestureWithStroke(fin)
                runCatching { service.dispatchGesture(g, null, mainHandler) }
            }
            return
        }

        val moveTarget = pendingMove
        val targetX = moveTarget?.x ?: strokeAnchorX
        val targetY = moveTarget?.y ?: strokeAnchorY
        pendingMove = null

        val path = Path().apply {
            moveTo(strokeAnchorX, strokeAnchorY)
            lineTo(targetX, targetY)
        }
        val next = runCatching {
            current.continueStroke(path, 0L, if (moveTarget != null) 42L else 95L, true)
        }.getOrNull()
        if (next == null) {
            resetStrokeState()
            return
        }
        strokeAnchorX = targetX
        strokeAnchorY = targetY
        activeStroke = next
        strokeInFlight = true
        val ok = runCatching {
            val g = buildGestureWithStroke(next)
            service.dispatchGesture(g, strokeCallback, mainHandler)
        }.getOrDefault(false)
        if (!ok) {
            resetStrokeState()
        }
    }

    private val strokeCallback = object : AccessibilityService.GestureResultCallback() {
        override fun onCompleted(gestureDescription: GestureDescription?) {
            strokeInFlight = false
            if (activeStroke != null && (pointerDown || pendingUp != null)) {
                pumpContinuedStroke()
            } else {
                resetStrokeState()
            }
        }

        override fun onCancelled(gestureDescription: GestureDescription?) {
            resetStrokeState()
        }
    }

    private fun resetStrokeState() {
        strokeInFlight = false
        activeStroke = null
        pendingMove = null
        pendingUp = null
    }

    private fun flushScrollLocked(screenW: Int, screenH: Int) {
        val dx = accumScrollDx.coerceIn(-screenW * 0.45f, screenW * 0.45f)
        val dy = accumScrollDy.coerceIn(-screenH * 0.45f, screenH * 0.45f)
        accumScrollDx = 0f
        accumScrollDy = 0f
        if (hypot(dx, dy) < 4f) return

        val endX = (lastScrollX + dx).coerceIn(8f, (screenW - 8).toFloat())
        val endY = (lastScrollY + dy).coerceIn(8f, (screenH - 8).toFloat())
        if (hypot(endX - lastScrollX, endY - lastScrollY) < 3f) return

        val path = Path().apply {
            moveTo(lastScrollX, lastScrollY)
            lineTo(endX, endY)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0L, 85L, false)
        val gesture = buildGestureWithStroke(stroke)
        scrollInFlight = true
        val ok = runCatching {
            service.dispatchGesture(
                gesture,
                object : AccessibilityService.GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        scrollInFlight = false
                        if (hypot(accumScrollDx, accumScrollDy) >= 6f) {
                            val (nw, nh) = displayBoundsProvider()
                            flushScrollLocked(nw, nh)
                        }
                    }

                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        scrollInFlight = false
                        accumScrollDx = 0f
                        accumScrollDy = 0f
                    }
                },
                mainHandler
            )
        }.getOrDefault(false)
        if (!ok) {
            scrollInFlight = false
        }
    }
}
