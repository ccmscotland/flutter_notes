package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

/**
 * Feature 0x1982 BacklightV2/V3 configuration. Durations are in seconds (5-second units on the wire).
 * [mode]: 0 = enabled (device decides), 1 = automatic (ambient light), 3 = manual level.
 */
data class BacklightInfo(
    val enabled: Boolean,
    val mode: Int,
    val supportsAutomatic: Boolean,
    val supportsManual: Boolean,
    val level: Int,
    val levelCount: Int?,
    val durationHandsOutSeconds: Int,
    val durationHandsInSeconds: Int,
    val durationPoweredSeconds: Int,
    private val options: Int,
) {
    companion object {
        const val MODE_ENABLED = 0
        const val MODE_AUTOMATIC = 1
        const val MODE_MANUAL = 3
    }

    internal fun rawOptions(): Int = options
}

object Backlight {
    private fun u16le(r: ByteArray, i: Int): Int = r[i].u() or (r[i + 1].u() shl 8)

    /** getBacklightConfig, little-endian layout as decoded by Solaar: enabled, options, supported, effects(2), level, dho(2), dhi(2), dpow(2). */
    suspend fun read(device: Hidpp20Device): BacklightInfo? {
        val r = device.callOrNull(Features.BACKLIGHT_V2, 0) ?: return null
        val options = r[1].u()
        val supported = r[2].u()
        val levelCount = device.callOrNull(Features.BACKLIGHT_V2, 2)?.get(0)?.u()?.takeIf { it > 1 }
        return BacklightInfo(
            enabled = r[0].u() and 0x01 != 0,
            mode = (options shr 3) and 0x03,
            supportsAutomatic = supported and 0x08 != 0,
            supportsManual = supported and 0x20 != 0 || supported and 0x10 != 0,
            level = r[5].u(),
            levelCount = levelCount,
            durationHandsOutSeconds = u16le(r, 6) * 5,
            durationHandsInSeconds = u16le(r, 8) * 5,
            durationPoweredSeconds = u16le(r, 10) * 5,
            options = options,
        )
    }

    /** setBacklightConfig with the current values and the given overrides. */
    suspend fun write(
        device: Hidpp20Device,
        enabled: Boolean? = null,
        mode: Int? = null,
        level: Int? = null,
        durationHandsOutSeconds: Int? = null,
        durationHandsInSeconds: Int? = null,
        durationPoweredSeconds: Int? = null,
    ) {
        val cur = read(device) ?: throw IllegalStateException("No Backlight feature")
        val en = enabled ?: cur.enabled
        val m = mode ?: cur.mode
        val options = (cur.rawOptions() and 0x07) or ((m and 0x03) shl 3)
        val lvl = if (m == BacklightInfo.MODE_MANUAL) (level ?: cur.level) else 0
        fun units(seconds: Int) = (seconds + 4) / 5
        val dho = units(durationHandsOutSeconds ?: cur.durationHandsOutSeconds)
        val dhi = units(durationHandsInSeconds ?: cur.durationHandsInSeconds)
        val dpow = units(durationPoweredSeconds ?: cur.durationPoweredSeconds)
        device.call(
            Features.BACKLIGHT_V2, 1,
            byteArrayOf(
                if (en) 1 else 0, options.toByte(), 0xFF.toByte(), lvl.toByte(),
                dho.toByte(), (dho shr 8).toByte(), dhi.toByte(), (dhi shr 8).toByte(), dpow.toByte(), (dpow shr 8).toByte(),
            ),
        )
    }
}
