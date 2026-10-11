package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

data class WheelInfo(
    val multiplier: Int,
    val invertible: Boolean,
    val hasRatchetSwitch: Boolean,
    val inverted: Boolean,
    val highResolution: Boolean,
    val diverted: Boolean,
)

/** Feature 0x2121 HiResWheel. Mode bits: 0x01 divert to HID++, 0x02 high resolution, 0x04 invert. */
object HiResWheel {
    private const val MODE_DIVERT = 0x01
    private const val MODE_HIRES = 0x02
    private const val MODE_INVERT = 0x04

    suspend fun read(device: Hidpp20Device): WheelInfo? {
        val caps = device.callOrNull(Features.HIRES_WHEEL, 0) ?: return null
        val mode = device.call(Features.HIRES_WHEEL, 1)[0].u()
        return WheelInfo(
            multiplier = caps[0].u(),
            invertible = caps[1].u() and 0x08 != 0,
            hasRatchetSwitch = caps[1].u() and 0x04 != 0,
            inverted = mode and MODE_INVERT != 0,
            highResolution = mode and MODE_HIRES != 0,
            diverted = mode and MODE_DIVERT != 0,
        )
    }

    suspend fun set(device: Hidpp20Device, inverted: Boolean? = null, highResolution: Boolean? = null, diverted: Boolean? = null) {
        var mode = device.call(Features.HIRES_WHEEL, 1)[0].u()
        fun apply(bit: Int, v: Boolean?) { if (v != null) mode = if (v) mode or bit else mode and bit.inv() }
        apply(MODE_INVERT, inverted); apply(MODE_HIRES, highResolution); apply(MODE_DIVERT, diverted)
        device.call(Features.HIRES_WHEEL, 2, byteArrayOf(mode.toByte()))
    }
}
