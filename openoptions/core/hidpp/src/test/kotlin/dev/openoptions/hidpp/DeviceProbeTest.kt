package dev.openoptions.hidpp

import dev.openoptions.hidpp.features.Battery
import dev.openoptions.hidpp.features.BatteryLevel
import dev.openoptions.hidpp.features.ChargingStatus
import dev.openoptions.hidpp.features.DeviceType
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DeviceProbeTest {

    @Test
    fun `probe reads name type firmware battery and features from a mouse behind a receiver`() = runTest {
        val fake = FakeHidppDevice().apply { devices[1] = FakeHidppDevice.mxMaster3s() }
        val channel = HidppChannel(fake, backgroundScope)
        val r = DeviceProbe.probe(channel, 1)
        assertEquals("MX Master 3S", r.name)
        assertEquals(DeviceType.MOUSE, r.type)
        assertEquals(ProtocolVersion(4, 5), r.protocol)
        assertEquals(72, r.battery!!.percent)
        assertEquals(BatteryLevel.GOOD, r.battery!!.level)
        assertEquals(ChargingStatus.DISCHARGING, r.battery!!.status)
        assertEquals(12, r.features.size) // Root + 11
        assertTrue(r.features.any { it.id == Features.REPROG_CONTROLS_V4 && it.index == 5 })
        assertEquals("Firmware MPM26.01.B001A", r.firmware[0].toString())
        assertEquals("Bootloader BL101.07.B0005", r.firmware[1].toString())
        assertEquals(0xB034, r.firmware[0].productId)
        assertTrue(r.summary().contains("MX Master 3S"))
    }

    @Test
    fun `probe on a direct BLE device uses index FF and long reports only`() = runTest {
        val fake = FakeHidppDevice(direct = true).apply { devices[0xFF] = FakeHidppDevice.mxKeys() }
        val channel = HidppChannel(fake, backgroundScope)
        val r = DeviceProbe.probe(channel, HidppChannel.DIRECT_DEVICE_INDEX)
        assertEquals("MX Keys", r.name)
        assertEquals(DeviceType.KEYBOARD, r.type)
        assertEquals(50, r.battery!!.percent)
        assertEquals(Features.BATTERY_STATUS, r.battery!!.sourceFeature)
        assertTrue(fake.written.all { it.type == ReportType.LONG })
        assertTrue(r.features.none { it.id == Features.UNIFIED_BATTERY })
    }

    @Test
    fun `probe on receiver index reports HID++ 1_0`() = runTest {
        val fake = FakeHidppDevice()
        val channel = HidppChannel(fake, backgroundScope)
        val r = DeviceProbe.probe(channel, HidppChannel.RECEIVER_INDEX)
        assertTrue(r.isReceiver)
        assertNull(r.name)
        assertEquals("[FF] Receiver (HID++ 1.0)", r.summary())
    }

    @Test
    fun `device name longer than one chunk is assembled`() = runTest {
        val longName = "Wireless Mouse With A Long Name"
        val fake = FakeHidppDevice().apply {
            devices[2] = FakeHidppDevice.Device(longName, 3, listOf(Features.FEATURE_SET, Features.DEVICE_NAME))
        }
        val channel = HidppChannel(fake, backgroundScope)
        assertEquals(longName, DeviceProbe.probe(channel, 2).name)
    }

    @Test
    fun `feature index cache avoids repeat Root lookups`() = runTest {
        val fake = FakeHidppDevice().apply { devices[1] = FakeHidppDevice.mxMaster3s() }
        val channel = HidppChannel(fake, backgroundScope)
        val device = Hidpp20Device(channel, 1)
        assertEquals(4, device.featureIndex(Features.UNIFIED_BATTERY))
        val before = fake.written.size
        assertEquals(4, device.featureIndex(Features.UNIFIED_BATTERY))
        assertNull(device.featureIndex(Features.ONBOARD_PROFILES))
        assertNull(device.featureIndex(Features.ONBOARD_PROFILES))
        assertEquals(before + 1, fake.written.size)
    }

    @Test
    fun `unified battery flags decode`() {
        val full = Battery.parseUnified(byteArrayOf(100, 0x08, 0x03, 0x01))
        assertEquals(BatteryLevel.FULL, full.level)
        assertEquals(ChargingStatus.FULL, full.status)
        val critical = Battery.parseUnified(byteArrayOf(3, 0x01, 0x00, 0x00))
        assertEquals(BatteryLevel.CRITICAL, critical.level)
        assertNotNull(critical.percent)
    }
}
