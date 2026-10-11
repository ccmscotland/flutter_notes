package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

data class DpiInfo(val current: Int, val default: Int, val supported: List<Int>)

/** Feature 0x2201 AdjustableDpi (sensor 0 only; multi-sensor devices are gaming mice). */
object AdjustableDpi {
    private const val SENSOR = 0

    suspend fun read(device: Hidpp20Device): DpiInfo? {
        val count = device.callOrNull(Features.ADJUSTABLE_DPI, 0)?.get(0)?.u() ?: return null
        if (count == 0) return null
        val list = parseDpiList(device.call(Features.ADJUSTABLE_DPI, 1, byteArrayOf(SENSOR.toByte())))
        val r = device.call(Features.ADJUSTABLE_DPI, 2, byteArrayOf(SENSOR.toByte()))
        val current = (r[1].u() shl 8) or r[2].u()
        val default = (r[3].u() shl 8) or r[4].u()
        return DpiInfo(if (current == 0) default else current, default, list)
    }

    suspend fun set(device: Hidpp20Device, dpi: Int) {
        require(dpi in 1..0xFFFF)
        device.call(Features.ADJUSTABLE_DPI, 3, byteArrayOf(SENSOR.toByte(), (dpi shr 8).toByte(), dpi.toByte()))
    }

    /**
     * Decodes getSensorDpiList: 16-bit values after the sensor index byte, 0 terminates. A value with the top three
     * bits set (0xE000 | step) is a range marker: continue from the previous value in steps of `step` up to the
     * value that follows the marker.
     */
    fun parseDpiList(r: ByteArray): List<Int> {
        val out = ArrayList<Int>()
        var i = 1
        while (i + 1 < r.size) {
            val v = (r[i].u() shl 8) or r[i + 1].u()
            if (v == 0) break
            if (v shr 13 == 0b111) {
                val step = v and 0x1FFF
                if (i + 3 >= r.size || out.isEmpty() || step == 0) break
                val last = (r[i + 2].u() shl 8) or r[i + 3].u()
                var next = out.last() + step
                while (next <= last) { out += next; next += step }
                i += 4
            } else {
                out += v
                i += 2
            }
        }
        return out
    }
}
