package dev.openoptions.hidpp

import dev.openoptions.hidpp.features.AdjustableDpi
import dev.openoptions.hidpp.features.Backlight
import dev.openoptions.hidpp.features.FnInversion
import dev.openoptions.hidpp.features.HiResWheel
import dev.openoptions.hidpp.features.SmartShift
import dev.openoptions.hidpp.features.ThumbWheel

/**
 * The settings a user has chosen for a device. Null means "leave the device as it is". Applied on every
 * connection so a device that was used elsewhere comes back configured.
 */
data class SettingsOverrides(
    val dpi: Int? = null,
    val ratchet: Boolean? = null,
    val smartShiftThreshold: Int? = null,
    val wheelInverted: Boolean? = null,
    val wheelHighRes: Boolean? = null,
    val thumbInverted: Boolean? = null,
    val fKeysDefault: Boolean? = null,
    val backlightEnabled: Boolean? = null,
    val backlightMode: Int? = null,
    val backlightLevel: Int? = null,
) {
    val isEmpty: Boolean
        get() = dpi == null && ratchet == null && smartShiftThreshold == null && wheelInverted == null && wheelHighRes == null &&
            thumbInverted == null && fKeysDefault == null && backlightEnabled == null && backlightMode == null && backlightLevel == null

    /** Writes every non-null field. A field the device rejects or lacks is reported and skipped. */
    suspend fun applyTo(device: Hidpp20Device, onError: (String, Throwable) -> Unit = { _, _ -> }): Int {
        var applied = 0
        suspend fun step(name: String, block: suspend () -> Unit) {
            try { block(); applied++ } catch (e: HidppException) { onError(name, e) } catch (e: IllegalStateException) { onError(name, e) }
        }
        dpi?.let { step("dpi") { AdjustableDpi.set(device, it) } }
        if (ratchet != null || smartShiftThreshold != null) step("smartShift") { SmartShift.set(device, ratchet, smartShiftThreshold) }
        if (wheelInverted != null || wheelHighRes != null) step("wheel") { HiResWheel.set(device, inverted = wheelInverted, highResolution = wheelHighRes) }
        thumbInverted?.let { step("thumbWheel") { ThumbWheel.set(device, inverted = it) } }
        fKeysDefault?.let { step("fnInversion") { FnInversion.set(device, it) } }
        if (backlightEnabled != null || backlightMode != null || backlightLevel != null) {
            step("backlight") { Backlight.write(device, enabled = backlightEnabled, mode = backlightMode, level = backlightLevel) }
        }
        return applied
    }
}
