package dev.openoptions.hidpp.features

import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.u

enum class ChargingStatus(val label: String) {
    DISCHARGING("Discharging"), CHARGING("Charging"), SLOW_CHARGING("Charging slowly"), FULL("Full"),
    ERROR("Charging error"), UNKNOWN("Unknown");
}

enum class BatteryLevel(val label: String) { CRITICAL("Critical"), LOW("Low"), GOOD("Good"), FULL("Full") }

data class BatteryInfo(
    val percent: Int?,
    val level: BatteryLevel?,
    val status: ChargingStatus,
    val voltageMillivolts: Int? = null,
    val sourceFeature: Int,
) {
    override fun toString(): String = buildString {
        percent?.let { append("$it%") }
        level?.let { if (isNotEmpty()) append(", "); append(it.label) }
        voltageMillivolts?.let { if (isNotEmpty()) append(", "); append("${it}mV") }
        if (isNotEmpty()) append(", ")
        append(status.label)
    }
}

/** Reads battery state from whichever of 0x1004, 0x1000 or 0x1001 the device implements. */
object Battery {
    suspend fun read(device: Hidpp20Device): BatteryInfo? =
        readUnified(device) ?: readLegacy(device) ?: readVoltage(device)

    /** Feature 0x1004 UnifiedBattery.getStatus */
    suspend fun readUnified(device: Hidpp20Device): BatteryInfo? {
        val r = device.callOrNull(Features.UNIFIED_BATTERY, 1) ?: return null
        return parseUnified(r)
    }

    fun parseUnified(r: ByteArray): BatteryInfo {
        val soc = r[0].u()
        val levelFlags = r[1].u()
        val level = when {
            levelFlags and 0x01 != 0 -> BatteryLevel.CRITICAL
            levelFlags and 0x02 != 0 -> BatteryLevel.LOW
            levelFlags and 0x04 != 0 -> BatteryLevel.GOOD
            levelFlags and 0x08 != 0 -> BatteryLevel.FULL
            else -> null
        }
        val status = when (r[2].u()) {
            0 -> ChargingStatus.DISCHARGING
            1 -> ChargingStatus.CHARGING
            2 -> ChargingStatus.SLOW_CHARGING
            3 -> ChargingStatus.FULL
            4 -> ChargingStatus.ERROR
            else -> ChargingStatus.UNKNOWN
        }
        return BatteryInfo(percent = if (soc in 0..100) soc else null, level = level, status = status, sourceFeature = Features.UNIFIED_BATTERY)
    }

    /** Feature 0x1000 BatteryStatus.getBatteryLevelStatus */
    suspend fun readLegacy(device: Hidpp20Device): BatteryInfo? {
        val r = device.callOrNull(Features.BATTERY_STATUS, 0) ?: return null
        return parseLegacy(r)
    }

    fun parseLegacy(r: ByteArray): BatteryInfo {
        val percent = r[0].u()
        val status = when (r[2].u()) {
            0 -> ChargingStatus.DISCHARGING
            1 -> ChargingStatus.CHARGING
            2 -> ChargingStatus.CHARGING // almost full
            3 -> ChargingStatus.FULL
            4 -> ChargingStatus.SLOW_CHARGING
            5, 6 -> ChargingStatus.ERROR
            else -> ChargingStatus.UNKNOWN
        }
        val level = when {
            percent <= 5 -> BatteryLevel.CRITICAL
            percent <= 20 -> BatteryLevel.LOW
            percent >= 90 -> BatteryLevel.FULL
            else -> BatteryLevel.GOOD
        }
        return BatteryInfo(percent = percent, level = level, status = status, sourceFeature = Features.BATTERY_STATUS)
    }

    /** Feature 0x1001 BatteryVoltage.getBatteryVoltage */
    suspend fun readVoltage(device: Hidpp20Device): BatteryInfo? {
        val r = device.callOrNull(Features.BATTERY_VOLTAGE, 0) ?: return null
        val mv = (r[0].u() shl 8) or r[1].u()
        val flags = r[2].u()
        val status = when {
            flags and 0x80 == 0 -> ChargingStatus.DISCHARGING
            flags and 0x03 == 0 -> ChargingStatus.CHARGING
            flags and 0x03 == 1 -> ChargingStatus.FULL
            flags and 0x03 == 2 -> ChargingStatus.SLOW_CHARGING
            else -> ChargingStatus.ERROR
        }
        return BatteryInfo(percent = null, level = null, status = status, voltageMillivolts = mv, sourceFeature = Features.BATTERY_VOLTAGE)
    }
}
