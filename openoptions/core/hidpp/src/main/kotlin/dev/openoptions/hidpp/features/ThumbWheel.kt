package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

data class ThumbWheelInfo(val diverted: Boolean, val inverted: Boolean)

/** Feature 0x2150 ThumbWheel: status is [divert, invert]; both set with function 2. */
object ThumbWheel {
    suspend fun read(device: Hidpp20Device): ThumbWheelInfo? {
        val r = device.callOrNull(Features.THUMB_WHEEL, 1) ?: return null
        return ThumbWheelInfo(diverted = r[0].u() != 0, inverted = r[1].u() != 0)
    }

    suspend fun set(device: Hidpp20Device, diverted: Boolean? = null, inverted: Boolean? = null) {
        val cur = read(device) ?: throw IllegalStateException("No ThumbWheel feature")
        val d = diverted ?: cur.diverted
        val i = inverted ?: cur.inverted
        device.call(Features.THUMB_WHEEL, 2, byteArrayOf(if (d) 1 else 0, if (i) 1 else 0))
    }
}
