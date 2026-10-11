package dev.openoptions.ui

import dev.openoptions.actions.AndroidAction

/** Everything the settings UI can ask a device owner to do. Implemented by the device and diagnostics view models. */
interface SettingsActions {
    fun setDpi(dpi: Int)
    fun setRatchet(ratchet: Boolean)
    fun setSmartShiftThreshold(t: Int)
    fun setWheelInverted(v: Boolean)
    fun setWheelHighRes(v: Boolean)
    fun setThumbInverted(v: Boolean)
    fun setFnKeysDefault(v: Boolean)
    fun setBacklightEnabled(v: Boolean)
    fun setBacklightMode(mode: Int)
    fun setBacklightLevel(level: Int)
    fun switchHost(host: Int)
    fun bind(cid: Int, action: AndroidAction)
    fun openAccessibilitySettings()
}
