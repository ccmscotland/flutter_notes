package dev.openoptions.hidpp

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HidppChannelTest {

    @Test
    fun `ping returns protocol version from fake device`() = runTest {
        val fake = FakeHidppDevice().apply { devices[1] = FakeHidppDevice.mxMaster3s() }
        val channel = HidppChannel(fake, backgroundScope)
        val device = Hidpp20Device(channel, 1)
        assertEquals(ProtocolVersion(4, 5), device.ping())
        // Short request chosen for 3 params on a USB-like transport.
        assertEquals(ReportType.SHORT, fake.written.single().type)
        assertTrue(fake.written.single().softwareId in 1..15)
    }

    @Test
    fun `receiver answers ping with HID++ 1_0`() = runTest {
        val fake = FakeHidppDevice()
        val channel = HidppChannel(fake, backgroundScope)
        assertEquals(ProtocolVersion(1, 0), Hidpp20Device(channel, HidppChannel.RECEIVER_INDEX).ping())
    }

    @Test
    fun `empty receiver slot raises UnknownDevice`() = runTest {
        val fake = FakeHidppDevice()
        val channel = HidppChannel(fake, backgroundScope)
        try {
            Hidpp20Device(channel, 3).ping()
            fail("expected Hidpp10Exception")
        } catch (e: Hidpp10Exception) {
            assertEquals(Hidpp10Error.UNKNOWN_DEVICE, e.code)
        }
    }

    @Test
    fun `silence raises timeout`() = runTest {
        val fake = FakeHidppDevice().apply { devices[1] = FakeHidppDevice.mxMaster3s(); dropNext = true }
        val channel = HidppChannel(fake, backgroundScope, timeoutMs = 200)
        try {
            Hidpp20Device(channel, 1).ping()
            fail("expected timeout")
        } catch (_: HidppTimeoutException) {
        }
    }

    @Test
    fun `HID++ 2_0 error is mapped`() = runTest {
        val fake = FakeHidppDevice().apply { devices[1] = FakeHidppDevice.mxMaster3s() }
        val channel = HidppChannel(fake, backgroundScope)
        try {
            channel.call(1, 0x00, 9) // Root has no function 9
            fail("expected Hidpp20Exception")
        } catch (e: Hidpp20Exception) {
            assertEquals(Hidpp20Error.INVALID_FUNCTION_ID, e.code)
        }
    }

    @Test
    fun `unrelated frames go to notifications`() = runTest {
        val fake = FakeHidppDevice().apply { devices[1] = FakeHidppDevice.mxMaster3s() }
        val channel = HidppChannel(fake, backgroundScope)
        val collected = ArrayList<HidppFrame>()
        backgroundScope.launch { channel.notifications.collect { collected += it } }
        runCurrent()
        // Battery event: feature index 4 (UnifiedBattery), function 0, swId 0.
        fake.emit(HidppFrame.build(ReportType.LONG, 1, 0x04, 0x00, byteArrayOf(50, 0x04, 0, 0)))
        runCurrent()
        assertEquals(1, collected.size)
        assertEquals(0, collected.single().softwareId)
    }

    @Test
    fun `register read on receiver`() = runTest {
        val fake = FakeHidppDevice()
        val channel = HidppChannel(fake, backgroundScope)
        // The fake receiver does not implement registers; it answers with a 1.0 error that must be mapped.
        try {
            channel.readRegister(HidppChannel.RECEIVER_INDEX, 0xB5, byteArrayOf(0x20))
            fail("expected Hidpp10Exception")
        } catch (e: Hidpp10Exception) {
            assertEquals(0x81, e.subId)
            assertEquals(0xB5, e.address)
        }
        assertEquals(ReportType.SHORT, fake.written.single().type)
    }

    @Test
    fun `trace sees both directions`() = runTest {
        val fake = FakeHidppDevice().apply { devices[1] = FakeHidppDevice.mxMaster3s() }
        val channel = HidppChannel(fake, backgroundScope)
        val seen = ArrayList<HidppChannel.Direction>()
        backgroundScope.launch { channel.trace.collect { seen += it.first } }
        runCurrent()
        Hidpp20Device(channel, 1).ping()
        runCurrent()
        assertEquals(listOf(HidppChannel.Direction.OUT, HidppChannel.Direction.IN), seen)
    }
}
