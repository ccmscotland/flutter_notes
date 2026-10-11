package dev.openoptions.hidpp

import dev.openoptions.hidpp.features.BatteryEvents
import dev.openoptions.hidpp.features.ChargingStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsOverridesTest {

    @Test
    fun `overrides apply to a mouse and skip features it lacks`() = runTest {
        val state = FakeHidppDevice.mxMaster3s()
        val fake = FakeHidppDevice().apply { devices[1] = state }
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 1)
        val errors = ArrayList<String>()
        val o = SettingsOverrides(dpi = 1800, ratchet = false, wheelInverted = true, fKeysDefault = true, backlightLevel = 3)
        val applied = o.applyTo(device) { name, _ -> errors += name }
        assertEquals(1800, state.dpi)
        assertEquals(1, state.smartShiftMode)
        assertEquals(0x06, state.wheelMode)
        assertEquals(listOf("fnInversion", "backlight"), errors)
        assertEquals(3, applied)
    }

    @Test
    fun `empty overrides do nothing`() = runTest {
        val fake = FakeHidppDevice().apply { devices[1] = FakeHidppDevice.mxMaster3s() }
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 1)
        assertTrue(SettingsOverrides().isEmpty)
        assertEquals(0, SettingsOverrides().applyTo(device))
        assertTrue(fake.written.isEmpty())
    }

    @Test
    fun `battery events decode by feature index`() {
        val unified = HidppFrame.build(ReportType.LONG, 0xFF, 0x07, 0x00, byteArrayOf(95, 0x08, 0x01, 0x01))
        val b = BatteryEvents.parse(unified, unifiedIndex = 0x07, legacyIndex = null)!!
        assertEquals(95, b.percent)
        assertEquals(ChargingStatus.CHARGING, b.status)
        // a response with the same feature index is not an event
        assertNull(BatteryEvents.parse(HidppFrame.build(ReportType.LONG, 0xFF, 0x07, 0x1A, byteArrayOf(95, 8, 1, 1)), 0x07, null))
        // another feature's event
        assertNull(BatteryEvents.parse(HidppFrame.build(ReportType.LONG, 0xFF, 0x0A, 0x00), 0x07, null))
    }
}
