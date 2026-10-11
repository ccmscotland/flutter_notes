package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

/** True when F1..F12 act as function keys by default (media keys need Fn). */
data class FnInversionInfo(val featureId: Int, val fKeysDefault: Boolean)

/** Features 0x40A0, 0x40A2 and 0x40A3 (the last one is per host and needs the current host index). */
object FnInversion {
    suspend fun read(device: Hidpp20Device): FnInversionInfo? {
        if (device.hasFeature(Features.K375S_FN_INVERSION)) {
            val host = Hosts.currentHostIndex(device)
            val r = device.call(Features.K375S_FN_INVERSION, 0, byteArrayOf(host.toByte()))
            return FnInversionInfo(Features.K375S_FN_INVERSION, r[1].u() and 0x01 != 0)
        }
        for (f in listOf(Features.NEW_FN_INVERSION, Features.FN_INVERSION)) {
            val r = device.callOrNull(f, 0) ?: continue
            return FnInversionInfo(f, r[0].u() and 0x01 != 0)
        }
        return null
    }

    suspend fun set(device: Hidpp20Device, fKeysDefault: Boolean) {
        val v: Byte = if (fKeysDefault) 1 else 0
        if (device.hasFeature(Features.K375S_FN_INVERSION)) {
            val host = Hosts.currentHostIndex(device)
            device.call(Features.K375S_FN_INVERSION, 1, byteArrayOf(host.toByte(), v))
            return
        }
        for (f in listOf(Features.NEW_FN_INVERSION, Features.FN_INVERSION)) {
            if (device.hasFeature(f)) { device.call(f, 1, byteArrayOf(v)); return }
        }
        throw IllegalStateException("No FN inversion feature")
    }
}
