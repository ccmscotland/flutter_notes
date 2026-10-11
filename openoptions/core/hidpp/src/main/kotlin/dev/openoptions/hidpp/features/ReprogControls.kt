package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

/** One control (button or key) from 0x1B04 getCidInfo. */
data class ControlInfo(
    val cid: Int,
    val taskId: Int,
    val flags: Int,
    val position: Int,
    val group: Int,
    val groupMask: Int,
) {
    val name: String get() = ControlIds.name(cid)
    val isMouseButton: Boolean get() = flags and 0x01 != 0
    val isFnKey: Boolean get() = flags and 0x02 != 0
    val reprogrammable: Boolean get() = flags and 0x10 != 0
    val divertable: Boolean get() = flags and 0x20 != 0
    val persistentlyDivertable: Boolean get() = flags and 0x40 != 0
    val virtual: Boolean get() = flags and 0x80 != 0
    val rawXy: Boolean get() = flags and 0x100 != 0
    val forceRawXy: Boolean get() = flags and 0x200 != 0
}

/** Current reporting state of a control from getCidReporting. */
data class ControlReporting(val cid: Int, val diverted: Boolean, val persistentlyDiverted: Boolean, val rawXy: Boolean, val remappedTo: Int) {
    val isRemapped: Boolean get() = remappedTo != 0 && remappedTo != cid
}

/** Feature 0x1B04 ReprogControlsV4. */
object ReprogControls {
    suspend fun list(device: Hidpp20Device): List<ControlInfo> {
        val count = device.callOrNull(Features.REPROG_CONTROLS_V4, 0)?.get(0)?.u() ?: return emptyList()
        return (0 until count).map { i ->
            val r = device.call(Features.REPROG_CONTROLS_V4, 1, byteArrayOf(i.toByte()))
            ControlInfo(
                cid = (r[0].u() shl 8) or r[1].u(),
                taskId = (r[2].u() shl 8) or r[3].u(),
                flags = r[4].u() or (r[8].u() shl 8),
                position = r[5].u(),
                group = r[6].u(),
                groupMask = r[7].u(),
            )
        }
    }

    suspend fun reporting(device: Hidpp20Device, cid: Int): ControlReporting {
        val r = device.call(Features.REPROG_CONTROLS_V4, 2, byteArrayOf((cid shr 8).toByte(), cid.toByte()))
        val flags = r[2].u()
        return ControlReporting(
            cid = (r[0].u() shl 8) or r[1].u(),
            diverted = flags and 0x01 != 0,
            persistentlyDiverted = flags and 0x04 != 0,
            rawXy = flags and 0x10 != 0,
            remappedTo = (r[3].u() shl 8) or r[4].u(),
        )
    }

    /**
     * setCidReporting. Each flag is sent with its "valid" bit so that null leaves the device value untouched.
     * [remapTo] 0 keeps the current mapping; use [cid] itself to restore the default.
     */
    suspend fun setReporting(device: Hidpp20Device, cid: Int, diverted: Boolean? = null, persistentlyDiverted: Boolean? = null, rawXy: Boolean? = null, remapTo: Int = 0) {
        var flags = 0
        fun put(bit: Int, v: Boolean?) { if (v != null) flags = flags or (bit shl 1) or (if (v) bit else 0) }
        put(0x01, diverted); put(0x04, persistentlyDiverted); put(0x10, rawXy)
        device.call(
            Features.REPROG_CONTROLS_V4, 3,
            byteArrayOf((cid shr 8).toByte(), cid.toByte(), flags.toByte(), (remapTo shr 8).toByte(), remapTo.toByte()),
        )
    }
}

/** Control ID names, from Logitech's published list as used by Solaar. Unknown ids print as hex. */
object ControlIds {
    private val names = mapOf(
        0x0001 to "Volume up", 0x0002 to "Volume down", 0x0003 to "Mute", 0x0004 to "Play/Pause",
        0x0005 to "Next track", 0x0006 to "Previous track", 0x0007 to "Stop",
        0x0008 to "Application switcher", 0x000A to "Calculator", 0x000E to "Mail",
        0x0050 to "Left button", 0x0051 to "Right button", 0x0052 to "Middle button", 0x0053 to "Back button",
        0x0056 to "Forward button", 0x005B to "Left scroll", 0x005D to "Right scroll",
        0x00C3 to "Gesture button", 0x00C4 to "SmartShift button", 0x00D7 to "Virtual gesture button",
        0x00DD to "Dictation", 0x00DE to "Emoji", 0x00DF to "Screen capture", 0x00E0 to "Mute microphone",
        0x00E6 to "Lock screen", 0x00E8 to "Backlight down", 0x00E9 to "Backlight up",
        0x00ED to "Multiplatform search", 0x00F1 to "Show desktop",
        0x0101 to "Brightness down", 0x0102 to "Brightness up",
    )

    fun name(cid: Int): String = names[cid] ?: "Control 0x%04X".format(cid)
}
