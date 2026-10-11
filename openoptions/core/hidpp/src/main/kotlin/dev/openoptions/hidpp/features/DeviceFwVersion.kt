package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

data class FirmwareInfo(val kind: Int, val prefix: String, val version: String, val build: Int, val productId: Int) {
    val kindLabel: String
        get() = when (kind) {
            0 -> "Firmware"
            1 -> "Bootloader"
            2 -> "Hardware"
            3 -> "Touchpad"
            4 -> "Optical sensor"
            5 -> "SoftDevice"
            6 -> "RF companion MCU"
            7 -> "Factory app"
            8 -> "RGB custom effect"
            9 -> "Motor drive"
            else -> "Other($kind)"
        }

    override fun toString(): String = "$kindLabel $prefix$version.B%04X".format(build)
}

/** Feature 0x0003 DeviceFwVersion. */
object DeviceFwVersion {
    suspend fun list(device: Hidpp20Device): List<FirmwareInfo> {
        val count = device.callOrNull(Features.DEVICE_FW_VERSION, 0)?.get(0)?.u() ?: return emptyList()
        return (0 until count).map { i ->
            val r = device.call(Features.DEVICE_FW_VERSION, 1, byteArrayOf(i.toByte()))
            FirmwareInfo(
                kind = r[0].u(),
                prefix = String(r.copyOfRange(1, 4), Charsets.US_ASCII).trimEnd('\u0000', ' '),
                version = "%02X.%02X".format(r[4].u(), r[5].u()),
                build = (r[6].u() shl 8) or r[7].u(),
                productId = if (r.size > 10) (r[9].u() shl 8) or r[10].u() else 0,
            )
        }
    }
}
