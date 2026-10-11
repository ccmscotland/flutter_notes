package dev.openoptions.hidpp

import dev.openoptions.hidpp.features.ControlEvent
import dev.openoptions.hidpp.features.ControlEvents
import dev.openoptions.hidpp.features.DivertedButtonTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ControlEventsTest {
    private val reprogIndex = 0x0A

    @Test
    fun `buttons notification decodes pressed cids`() {
        val f = HidppFrame.build(ReportType.LONG, 0xFF, reprogIndex, 0x00, byteArrayOf(0x00, 0x52, 0x00, 0x53, 0, 0, 0, 0))
        val e = ControlEvents.parse(f, reprogIndex) as ControlEvent.Buttons
        assertEquals(setOf(0x52, 0x53), e.pressed)
        val release = HidppFrame.build(ReportType.LONG, 0xFF, reprogIndex, 0x00)
        assertEquals(emptySet<Int>(), (ControlEvents.parse(release, reprogIndex) as ControlEvent.Buttons).pressed)
    }

    @Test
    fun `raw xy notification is signed`() {
        val f = HidppFrame.build(ReportType.LONG, 0xFF, reprogIndex, 0x10, byteArrayOf(0xFF.toByte(), 0xFB.toByte(), 0x00, 0x07))
        val e = ControlEvents.parse(f, reprogIndex) as ControlEvent.RawXy
        assertEquals(-5, e.dx)
        assertEquals(7, e.dy)
    }

    @Test
    fun `responses and other features are ignored`() {
        // same feature index but software id 0xA: a response, not an event
        assertNull(ControlEvents.parse(HidppFrame.build(ReportType.LONG, 0xFF, reprogIndex, 0x0A), reprogIndex))
        // battery event
        assertNull(ControlEvents.parse(HidppFrame.build(ReportType.LONG, 0xFF, 0x07, 0x00), reprogIndex))
    }

    @Test
    fun `tracker reports transitions once`() {
        val t = DivertedButtonTracker()
        var tr = t.update(setOf(0x52))
        assertEquals(listOf(0x52), tr.pressed); assertTrue(tr.released.isEmpty())
        tr = t.update(setOf(0x52, 0x53))
        assertEquals(listOf(0x53), tr.pressed); assertTrue(tr.released.isEmpty())
        tr = t.update(setOf(0x53))
        assertTrue(tr.pressed.isEmpty()); assertEquals(listOf(0x52), tr.released)
        tr = t.update(emptySet())
        assertEquals(listOf(0x53), tr.released)
        tr = t.update(emptySet())
        assertTrue(tr.pressed.isEmpty() && tr.released.isEmpty())
    }
}
