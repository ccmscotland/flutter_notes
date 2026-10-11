package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

/**
 * Ratchet / free-spin control. [threshold] is the auto-disengage force, 1..50 (255 on the wire means "never").
 */
data class SmartShiftInfo(val featureId: Int, val ratchet: Boolean, val threshold: Int) {
    val freeSpin: Boolean get() = !ratchet
}

/** Features 0x2110 SmartShift and 0x2111 SmartShiftEnhanced (same payload, different function ids). */
object SmartShift {
    const val MIN_THRESHOLD = 1
    const val MAX_THRESHOLD = 50
    private const val MODE_FREESPIN = 1
    private const val MODE_RATCHET = 2

    private suspend fun which(device: Hidpp20Device): Pair<Int, Int>? = when {
        device.hasFeature(Features.SMART_SHIFT_ENHANCED) -> Features.SMART_SHIFT_ENHANCED to 1
        device.hasFeature(Features.SMART_SHIFT) -> Features.SMART_SHIFT to 0
        else -> null
    }

    suspend fun read(device: Hidpp20Device): SmartShiftInfo? {
        val (feature, readFn) = which(device) ?: return null
        val r = device.call(feature, readFn)
        val raw = r[1].u()
        return SmartShiftInfo(feature, ratchet = r[0].u() == MODE_RATCHET, threshold = if (raw >= 255) MAX_THRESHOLD else raw.coerceIn(MIN_THRESHOLD, MAX_THRESHOLD))
    }

    /** Null arguments leave that field unchanged (0 on the wire). */
    suspend fun set(device: Hidpp20Device, ratchet: Boolean? = null, threshold: Int? = null) {
        val (feature, readFn) = which(device) ?: throw IllegalStateException("No SmartShift feature")
        val mode = when (ratchet) { null -> 0; true -> MODE_RATCHET; false -> MODE_FREESPIN }
        val t = when {
            threshold == null -> 0
            threshold >= MAX_THRESHOLD -> 255
            else -> threshold.coerceAtLeast(MIN_THRESHOLD)
        }
        device.call(feature, readFn + 1, byteArrayOf(mode.toByte(), t.toByte(), 0))
    }
}
