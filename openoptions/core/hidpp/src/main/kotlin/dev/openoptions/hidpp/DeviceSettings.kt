package dev.openoptions.hidpp

import dev.openoptions.hidpp.features.AdjustableDpi
import dev.openoptions.hidpp.features.Backlight
import dev.openoptions.hidpp.features.BacklightInfo
import dev.openoptions.hidpp.features.ControlInfo
import dev.openoptions.hidpp.features.DpiInfo
import dev.openoptions.hidpp.features.FnInversion
import dev.openoptions.hidpp.features.FnInversionInfo
import dev.openoptions.hidpp.features.HiResWheel
import dev.openoptions.hidpp.features.Hosts
import dev.openoptions.hidpp.features.HostsInfo
import dev.openoptions.hidpp.features.ReprogControls
import dev.openoptions.hidpp.features.SmartShift
import dev.openoptions.hidpp.features.SmartShiftInfo
import dev.openoptions.hidpp.features.ThumbWheel
import dev.openoptions.hidpp.features.ThumbWheelInfo
import dev.openoptions.hidpp.features.WheelInfo

/** Everything the settings screens show for one device; null sections are features the device lacks. */
data class DeviceSettingsSnapshot(
    val dpi: DpiInfo? = null,
    val smartShift: SmartShiftInfo? = null,
    val wheel: WheelInfo? = null,
    val thumbWheel: ThumbWheelInfo? = null,
    val backlight: BacklightInfo? = null,
    val fnInversion: FnInversionInfo? = null,
    val hosts: HostsInfo? = null,
    val controls: List<ControlInfo> = emptyList(),
)

object DeviceSettings {
    /** Reads every supported section. A section that fails is left null rather than failing the whole read. */
    suspend fun read(device: Hidpp20Device, onError: (String, Throwable) -> Unit = { _, _ -> }): DeviceSettingsSnapshot {
        suspend fun <T> section(name: String, block: suspend () -> T?): T? =
            try { block() } catch (e: HidppException) { onError(name, e); null }
        return DeviceSettingsSnapshot(
            dpi = section("dpi") { AdjustableDpi.read(device) },
            smartShift = section("smartShift") { SmartShift.read(device) },
            wheel = section("wheel") { HiResWheel.read(device) },
            thumbWheel = section("thumbWheel") { ThumbWheel.read(device) },
            backlight = section("backlight") { Backlight.read(device) },
            fnInversion = section("fnInversion") { FnInversion.read(device) },
            hosts = section("hosts") { Hosts.read(device) },
            controls = section("controls") { ReprogControls.list(device) } ?: emptyList(),
        )
    }
}
