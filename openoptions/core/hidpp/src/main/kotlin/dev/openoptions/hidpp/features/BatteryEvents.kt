package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.HidppFrame

/** Decodes unsolicited battery notifications from 0x1004 (event 0) and 0x1000 (event 0). */
object BatteryEvents {
    fun parse(frame: HidppFrame, unifiedIndex: Int?, legacyIndex: Int?): BatteryInfo? {
        if (frame.softwareId != 0 || frame.function != 0) return null
        return when (frame.subId) {
            unifiedIndex -> Battery.parseUnified(frame.params)
            legacyIndex -> Battery.parseLegacy(frame.params)
            else -> null
        }
    }
}
