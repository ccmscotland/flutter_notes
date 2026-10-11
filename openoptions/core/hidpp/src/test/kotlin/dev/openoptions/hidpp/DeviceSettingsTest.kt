package dev.openoptions.hidpp

import dev.openoptions.hidpp.features.AdjustableDpi
import dev.openoptions.hidpp.features.Backlight
import dev.openoptions.hidpp.features.BacklightInfo
import dev.openoptions.hidpp.features.FnInversion
import dev.openoptions.hidpp.features.HiResWheel
import dev.openoptions.hidpp.features.Hosts
import dev.openoptions.hidpp.features.ReprogControls
import dev.openoptions.hidpp.features.SmartShift
import dev.openoptions.hidpp.features.ThumbWheel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DeviceSettingsTest {

    private fun mouse(): Pair<FakeHidppDevice, FakeHidppDevice.Device> {
        val d = FakeHidppDevice.mxMaster3s()
        return FakeHidppDevice().apply { devices[1] = d } to d
    }

    private fun keyboard(): Pair<FakeHidppDevice, FakeHidppDevice.Device> {
        val d = FakeHidppDevice.mxKeys()
        return FakeHidppDevice(direct = true).apply { devices[0xFF] = d } to d
    }

    @Test
    fun `dpi list expands range markers`() {
        // 100, then marker step 50 up to 4000
        val list = AdjustableDpi.parseDpiList(byteArrayOf(0x00, 0x00, 0x64, 0xE0.toByte(), 0x32, 0x0F, 0xA0.toByte(), 0x00, 0x00))
        assertEquals(100, list.first())
        assertEquals(4000, list.last())
        assertEquals(79, list.size)
        assertTrue(list.contains(1650))
        // plain list
        assertEquals(listOf(400, 800, 1600), AdjustableDpi.parseDpiList(byteArrayOf(0, 0x01, 0x90.toByte(), 0x03, 0x20, 0x06, 0x40, 0, 0)))
    }

    @Test
    fun `dpi round trip`() = runTest {
        val (fake, state) = mouse()
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 1)
        val before = AdjustableDpi.read(device)!!
        assertEquals(1000, before.current)
        assertEquals(1000, before.default)
        AdjustableDpi.set(device, 1600)
        assertEquals(1600, state.dpi)
        assertEquals(1600, AdjustableDpi.read(device)!!.current)
    }

    @Test
    fun `smartshift read and partial update`() = runTest {
        val (fake, state) = mouse()
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 1)
        val s = SmartShift.read(device)!!
        assertEquals(Features.SMART_SHIFT_ENHANCED, s.featureId)
        assertTrue(s.ratchet)
        assertEquals(20, s.threshold)
        SmartShift.set(device, ratchet = false)
        assertEquals(1, state.smartShiftMode)
        assertEquals(20, state.smartShiftThreshold) // untouched
        SmartShift.set(device, threshold = 50)
        assertEquals(255, state.smartShiftThreshold) // max maps to "never"
        assertEquals(50, SmartShift.read(device)!!.threshold)
    }

    @Test
    fun `hires wheel bits`() = runTest {
        val (fake, state) = mouse()
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 1)
        val w = HiResWheel.read(device)!!
        assertTrue(w.invertible); assertTrue(w.hasRatchetSwitch); assertEquals(8, w.multiplier)
        assertTrue(w.highResolution); assertFalse(w.inverted); assertFalse(w.diverted)
        HiResWheel.set(device, inverted = true)
        assertEquals(0x06, state.wheelMode)
        HiResWheel.set(device, highResolution = false, diverted = true)
        assertEquals(0x05, state.wheelMode)
    }

    @Test
    fun `thumb wheel keeps the other flag`() = runTest {
        val (fake, state) = mouse()
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 1)
        ThumbWheel.set(device, inverted = true)
        assertEquals(0, state.thumbDivert); assertEquals(1, state.thumbInvert)
        ThumbWheel.set(device, diverted = true)
        assertEquals(1, state.thumbDivert); assertEquals(1, state.thumbInvert)
    }

    @Test
    fun `backlight decode and write`() = runTest {
        val (fake, state) = keyboard()
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 0xFF)
        val b = Backlight.read(device)!!
        assertTrue(b.enabled)
        assertEquals(BacklightInfo.MODE_MANUAL, b.mode)
        assertEquals(2, b.level)
        assertEquals(4, b.levelCount)
        assertEquals(60, b.durationHandsOutSeconds)
        assertEquals(30, b.durationHandsInSeconds)
        assertEquals(300, b.durationPoweredSeconds)
        assertTrue(b.supportsAutomatic)
        Backlight.write(device, level = 3, durationHandsOutSeconds = 47)
        assertEquals(3, state.backlightLevel)
        assertEquals(10, state.backlightDurations[0]) // 47 s rounds up to 10 units
        Backlight.write(device, enabled = false)
        assertEquals(0, state.backlightEnabled)
        Backlight.write(device, mode = BacklightInfo.MODE_AUTOMATIC)
        assertEquals(BacklightInfo.MODE_AUTOMATIC, Backlight.read(device)!!.mode)
    }

    @Test
    fun `fn inversion addresses the current host`() = runTest {
        val (fake, state) = keyboard()
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 0xFF)
        state.currentHost = 2
        assertFalse(FnInversion.read(device)!!.fKeysDefault)
        FnInversion.set(device, true)
        assertEquals(1, state.fnInverted[2])
        assertEquals(0, state.fnInverted[0])
        assertTrue(FnInversion.read(device)!!.fKeysDefault)
    }

    @Test
    fun `hosts list names current slot and rename`() = runTest {
        val (fake, state) = keyboard()
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 0xFF)
        val h = Hosts.read(device)!!
        assertEquals(3, h.hosts.size)
        assertEquals("Desk PC", h.hosts[0].name)
        assertFalse(h.hosts[1].paired)
        assertNull(h.hosts[1].name)
        assertEquals(1, h.current!!.index)
        assertTrue(h.canRename)
        Hosts.rename(device, 2, "Living room tablet")
        assertEquals("Living room tablet", state.hostNames[2])
        assertEquals("Living room tablet", Hosts.read(device)!!.hosts[2].name)
        Hosts.switchTo(device, 0)
        assertEquals(0, state.lastChangeHost)
    }

    @Test
    fun `controls list and reporting round trip`() = runTest {
        val (fake, state) = mouse()
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 1)
        val controls = ReprogControls.list(device)
        assertEquals(3, controls.size)
        assertEquals("Left button", controls[0].name)
        assertTrue(controls[0].isMouseButton); assertFalse(controls[0].divertable)
        val gesture = controls[2]
        assertEquals("Gesture button", gesture.name)
        assertTrue(gesture.divertable && gesture.persistentlyDivertable && gesture.reprogrammable)
        assertTrue(gesture.rawXy && gesture.forceRawXy)
        ReprogControls.setReporting(device, gesture.cid, diverted = true, rawXy = true)
        val rep = ReprogControls.reporting(device, gesture.cid)
        assertTrue(rep.diverted); assertTrue(rep.rawXy); assertFalse(rep.persistentlyDiverted); assertFalse(rep.isRemapped)
        ReprogControls.setReporting(device, gesture.cid, diverted = false, remapTo = 0x0053)
        val rep2 = ReprogControls.reporting(device, gesture.cid)
        assertFalse(rep2.diverted); assertTrue(rep2.rawXy); assertEquals(0x0053, rep2.remappedTo); assertTrue(rep2.isRemapped)
        assertNotNull(state.reporting[gesture.cid])
    }

    @Test
    fun `snapshot reads all sections and tolerates missing ones`() = runTest {
        val (fake, _) = keyboard()
        val device = Hidpp20Device(HidppChannel(fake, backgroundScope), 0xFF)
        val snap = DeviceSettings.read(device)
        assertNull(snap.dpi); assertNull(snap.smartShift); assertNull(snap.wheel); assertNull(snap.thumbWheel)
        assertNotNull(snap.backlight); assertNotNull(snap.fnInversion); assertNotNull(snap.hosts)
        assertEquals(3, snap.controls.size)
    }
}
