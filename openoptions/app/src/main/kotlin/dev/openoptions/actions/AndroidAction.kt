package dev.openoptions.actions

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.SystemClock
import android.view.KeyEvent

/** What a diverted button can do on Android. */
enum class AndroidAction(val label: String, val needsAccessibility: Boolean) {
    NONE("Device default", false),
    BACK("Back", true),
    HOME("Home", true),
    RECENTS("Recent apps", true),
    NOTIFICATIONS("Notifications", true),
    QUICK_SETTINGS("Quick settings", true),
    SCREENSHOT("Screenshot", true),
    LOCK_SCREEN("Lock screen", true),
    PLAY_PAUSE("Play / Pause", false),
    NEXT_TRACK("Next track", false),
    PREVIOUS_TRACK("Previous track", false),
    VOLUME_UP("Volume up", false),
    VOLUME_DOWN("Volume down", false),
    MUTE("Mute", false),
}

object ActionRunner {
    /** Performs [action]; returns a failure message or null. */
    fun run(context: Context, action: AndroidAction): String? {
        val globalAction = when (action) {
            AndroidAction.BACK -> AccessibilityService.GLOBAL_ACTION_BACK
            AndroidAction.HOME -> AccessibilityService.GLOBAL_ACTION_HOME
            AndroidAction.RECENTS -> AccessibilityService.GLOBAL_ACTION_RECENTS
            AndroidAction.NOTIFICATIONS -> AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS
            AndroidAction.QUICK_SETTINGS -> AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS
            AndroidAction.SCREENSHOT -> AccessibilityService.GLOBAL_ACTION_TAKE_SCREENSHOT
            AndroidAction.LOCK_SCREEN -> AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN
            else -> null
        }
        if (globalAction != null) {
            val service = ActionAccessibilityService.instance ?: return "accessibility service not enabled"
            return if (service.performGlobalAction(globalAction)) null else "performGlobalAction returned false"
        }
        val audio = context.getSystemService(AudioManager::class.java) ?: return "no AudioManager"
        when (action) {
            AndroidAction.PLAY_PAUSE -> mediaKey(audio, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            AndroidAction.NEXT_TRACK -> mediaKey(audio, KeyEvent.KEYCODE_MEDIA_NEXT)
            AndroidAction.PREVIOUS_TRACK -> mediaKey(audio, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            AndroidAction.VOLUME_UP -> audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI)
            AndroidAction.VOLUME_DOWN -> audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
            AndroidAction.MUTE -> audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_TOGGLE_MUTE, AudioManager.FLAG_SHOW_UI)
            AndroidAction.NONE -> return "no action bound"
            else -> return "unhandled action $action"
        }
        return null
    }

    private fun mediaKey(audio: AudioManager, keyCode: Int) {
        val now = SystemClock.uptimeMillis()
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0))
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, keyCode, 0))
    }

    val sdkNote: String? = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) "Screenshot and Lock screen need Android 9+" else null
}
