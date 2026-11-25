package ren.onekb.openuu

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap

/**
 * Android AccessibilityService entry point used only when the user enables Local Host mode.
 */
class OpenUURemoteInputService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: OpenUURemoteInputService? = null
            private set

        private val _connectedFlow = MutableStateFlow(false)
        val connectedFlow: StateFlow<Boolean> = _connectedFlow.asStateFlow()

        fun isEnabledInSettings(context: Context): Boolean {
            if (instance != null) return true
            return runCatching {
                val expected = ComponentName(context, OpenUURemoteInputService::class.java)
                val raw = Settings.Secure.getString(
                    context.contentResolver,
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                ).orEmpty()
                raw.split(':').any { token ->
                    val cn = ComponentName.unflattenFromString(token.trim())
                    cn == expected
                }
            }.getOrDefault(false)
        }
    }

    private lateinit var touchDispatcher: RemoteTouchDispatcher
    private val displayDispatchers = ConcurrentHashMap<Int, RemoteTouchDispatcher>()
    private val displayBoundsMap = ConcurrentHashMap<Int, Pair<Int, Int>>()

    override fun onServiceConnected() {
        super.onServiceConnected()
        touchDispatcher = RemoteTouchDispatcher(this, Display.DEFAULT_DISPLAY, ::queryRealDisplaySize)
        instance = this
        _connectedFlow.value = true
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Passive: OpenUU does not scrape or upload accessibility events.
    }

    override fun onInterrupt() {
        // No-op
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
            _connectedFlow.value = false
        }
        super.onDestroy()
    }

    fun dispatchMouse(normX: Float, normY: Float, eventType: Int, button: Int) {
        if (::touchDispatcher.isInitialized) {
            touchDispatcher.handlePointer(normX, normY, eventType, button)
        }
    }

    fun dispatchMouseOnDisplay(
        displayId: Int,
        displayW: Int,
        displayH: Int,
        normX: Float,
        normY: Float,
        eventType: Int,
        button: Int
    ) {
        if (displayId <= 0 || displayId == Display.DEFAULT_DISPLAY) {
            dispatchMouse(normX, normY, eventType, button)
            return
        }
        displayBoundsMap[displayId] = displayW.coerceAtLeast(2) to displayH.coerceAtLeast(2)
        val disp = displayDispatchers.getOrPut(displayId) {
            RemoteTouchDispatcher(this, displayId) {
                displayBoundsMap[displayId] ?: queryRealDisplaySize()
            }
        }
        disp.handlePointer(normX, normY, eventType, button)
    }

    fun dispatchScroll(
        normX: Float,
        normY: Float,
        deltaX: Float,
        deltaY: Float,
        isContinuous: Boolean
    ) {
        if (::touchDispatcher.isInitialized) {
            touchDispatcher.handleScroll(normX, normY, deltaX, deltaY, isContinuous)
        }
    }

    fun dispatchScrollOnDisplay(
        displayId: Int,
        displayW: Int,
        displayH: Int,
        normX: Float,
        normY: Float,
        deltaX: Float,
        deltaY: Float,
        isContinuous: Boolean
    ) {
        if (displayId <= 0 || displayId == Display.DEFAULT_DISPLAY) {
            dispatchScroll(normX, normY, deltaX, deltaY, isContinuous)
            return
        }
        displayBoundsMap[displayId] = displayW.coerceAtLeast(2) to displayH.coerceAtLeast(2)
        val disp = displayDispatchers.getOrPut(displayId) {
            RemoteTouchDispatcher(this, displayId) {
                displayBoundsMap[displayId] ?: queryRealDisplaySize()
            }
        }
        disp.handleScroll(normX, normY, deltaX, deltaY, isContinuous)
    }

    fun dispatchKey(keyCode: Int, isDown: Boolean, modifiers: Int) {
        RemoteTextCommitHelper.handleKeyEvent(this, keyCode, isDown, modifiers)
    }

    fun dispatchTextCommit(text: String) {
        RemoteTextCommitHelper.commitText(this, text)
    }

    private fun queryRealDisplaySize(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            ?: return 1080 to 2400
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = wm.maximumWindowMetrics.bounds
            bounds.width().coerceAtLeast(2) to bounds.height().coerceAtLeast(2)
        } else {
            val dm = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay?.getRealMetrics(dm)
            dm.widthPixels.coerceAtLeast(2) to dm.heightPixels.coerceAtLeast(2)
        }
    }
}
