package dev.openoptions.hidpp

/** HID++ 2.0 feature identifiers used by the app. */
object Features {
    const val ROOT = 0x0000
    const val FEATURE_SET = 0x0001
    const val FEATURE_INFO = 0x0002
    const val DEVICE_FW_VERSION = 0x0003
    const val DEVICE_UNIT_ID = 0x0004
    const val DEVICE_NAME = 0x0005
    const val DEVICE_GROUPS = 0x0006
    const val DEVICE_FRIENDLY_NAME = 0x0007
    const val RESET = 0x0020
    const val CRYPTO_ID = 0x0021
    const val DFU_CONTROL = 0x00C2
    const val BATTERY_STATUS = 0x1000
    const val BATTERY_VOLTAGE = 0x1001
    const val UNIFIED_BATTERY = 0x1004
    const val CHARGING_CONTROL = 0x1010
    const val CHANGE_HOST = 0x1814
    const val HOSTS_INFO = 0x1815
    const val BACKLIGHT_V2 = 0x1982
    const val BACKLIGHT_V3 = 0x1983
    const val REPROG_CONTROLS_V4 = 0x1B04
    const val WIRELESS_DEVICE_STATUS = 0x1D4B
    const val SMART_SHIFT = 0x2110
    const val SMART_SHIFT_ENHANCED = 0x2111
    const val HIRES_WHEEL = 0x2121
    const val THUMB_WHEEL = 0x2150
    const val ADJUSTABLE_DPI = 0x2201
    const val POINTER_SPEED = 0x2205
    const val FN_INVERSION = 0x40A0
    const val NEW_FN_INVERSION = 0x40A2
    const val K375S_FN_INVERSION = 0x40A3
    const val KEYBOARD_LAYOUT_2 = 0x4540
    const val REPORT_RATE = 0x8060
    const val ONBOARD_PROFILES = 0x8100

    private val names: Map<Int, String> = mapOf(
        ROOT to "Root",
        FEATURE_SET to "FeatureSet",
        FEATURE_INFO to "FeatureInfo",
        DEVICE_FW_VERSION to "DeviceFwVersion",
        DEVICE_UNIT_ID to "DeviceUnitId",
        DEVICE_NAME to "DeviceName",
        DEVICE_GROUPS to "DeviceGroups",
        DEVICE_FRIENDLY_NAME to "DeviceFriendlyName",
        RESET to "Reset",
        CRYPTO_ID to "CryptoId",
        DFU_CONTROL to "DfuControl",
        BATTERY_STATUS to "BatteryStatus",
        BATTERY_VOLTAGE to "BatteryVoltage",
        UNIFIED_BATTERY to "UnifiedBattery",
        CHARGING_CONTROL to "ChargingControl",
        CHANGE_HOST to "ChangeHost",
        HOSTS_INFO to "HostsInfo",
        BACKLIGHT_V2 to "BacklightV2",
        BACKLIGHT_V3 to "BacklightV3",
        REPROG_CONTROLS_V4 to "ReprogControlsV4",
        WIRELESS_DEVICE_STATUS to "WirelessDeviceStatus",
        SMART_SHIFT to "SmartShift",
        SMART_SHIFT_ENHANCED to "SmartShiftEnhanced",
        HIRES_WHEEL to "HiResWheel",
        THUMB_WHEEL to "ThumbWheel",
        ADJUSTABLE_DPI to "AdjustableDpi",
        POINTER_SPEED to "PointerSpeed",
        FN_INVERSION to "FnInversion",
        NEW_FN_INVERSION to "NewFnInversion",
        K375S_FN_INVERSION to "K375sFnInversion",
        KEYBOARD_LAYOUT_2 to "KeyboardLayout2",
        REPORT_RATE to "ReportRate",
        ONBOARD_PROFILES to "OnboardProfiles",
    )

    fun name(id: Int): String = names[id] ?: "0x%04X".format(id)
}

data class FeatureEntry(val index: Int, val id: Int, val type: Int, val version: Int) {
    val name: String get() = Features.name(id)
    val isObsolete: Boolean get() = type and 0x80 != 0
    val isHidden: Boolean get() = type and 0x40 != 0
    val isInternal: Boolean get() = type and 0x20 != 0
}

data class ProtocolVersion(val major: Int, val minor: Int) {
    val isHidpp10: Boolean get() = major == 1
    override fun toString(): String = "$major.$minor"
}
