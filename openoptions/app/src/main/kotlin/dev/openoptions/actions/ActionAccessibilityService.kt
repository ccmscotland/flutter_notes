package dev.openoptions.actions

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/**
 * Performs global actions (Back, Home, Recents, ...) on behalf of diverted buttons. The service does no
 * content inspection; it only exists so the app may call [performGlobalAction].
 */
class ActionAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Window changes will drive per-app profiles in Phase 3; nothing to do yet.
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile
        var instance: ActionAccessibilityService? = null
            private set

        val isRunning: Boolean get() = instance != null
    }
}
