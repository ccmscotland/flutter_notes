package dev.openoptions.hidpp

import dev.openoptions.hidpp.features.Battery
import dev.openoptions.hidpp.features.BatteryInfo
import dev.openoptions.hidpp.features.DeviceFwVersion
import dev.openoptions.hidpp.features.DeviceName
import dev.openoptions.hidpp.features.DeviceType
import dev.openoptions.hidpp.features.FirmwareInfo

/** Everything the Phase 0 spike needs to prove a transport works end to end. */
data class ProbeResult(
    val deviceIndex: Int,
    val protocol: ProtocolVersion,
    val name: String? = null,
    val type: DeviceType? = null,
    val firmware: List<FirmwareInfo> = emptyList(),
    val battery: BatteryInfo? = null,
    val features: List<FeatureEntry> = emptyList(),
) {
    val isReceiver: Boolean get() = protocol.isHidpp10 && deviceIndex == HidppChannel.RECEIVER_INDEX

    fun summary(): String = buildString {
        append("[${deviceIndex.hex()}] ")
        when {
            isReceiver -> append("Receiver (HID++ 1.0)")
            protocol.isHidpp10 -> append("HID++ 1.0 device")
            else -> {
                append(name ?: "Unnamed device")
                type?.let { append(" · ${it.label}") }
                append(" · HID++ $protocol")
                battery?.let { append(" · $it") }
                firmware.firstOrNull { it.kind == 0 }?.let { append(" · $it") }
                append(" · ${features.size} features")
            }
        }
    }
}

object DeviceProbe {
    /**
     * Pings [deviceIndex] and, for a HID++ 2.0 device, reads name, type, firmware, battery and the feature table.
     * Throws [HidppTimeoutException] when nothing answers and [Hidpp10Exception] for a receiver slot with no device.
     */
    suspend fun probe(channel: HidppChannel, deviceIndex: Int): ProbeResult {
        val device = Hidpp20Device(channel, deviceIndex)
        val protocol = device.ping()
        if (protocol.isHidpp10) return ProbeResult(deviceIndex, protocol)
        val features = device.listFeatures()
        return ProbeResult(
            deviceIndex = deviceIndex,
            protocol = protocol,
            name = DeviceName.name(device),
            type = DeviceName.type(device),
            firmware = DeviceFwVersion.list(device),
            battery = Battery.read(device),
            features = features,
        )
    }
}
