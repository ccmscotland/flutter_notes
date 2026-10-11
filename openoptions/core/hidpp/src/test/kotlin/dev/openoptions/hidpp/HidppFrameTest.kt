package dev.openoptions.hidpp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HidppFrameTest {

    @Test
    fun `short report round trips with report id`() {
        val f = HidppFrame.build(ReportType.SHORT, 0x01, 0x00, 0x1A, byteArrayOf(0, 0, 0x5A))
        val bytes = f.encode()
        assertArrayEquals(byteArrayOf(0x10, 0x01, 0x00, 0x1A, 0, 0, 0x5A), bytes)
        val back = HidppFrame.decode(bytes)!!
        assertEquals(ReportType.SHORT, back.type)
        assertEquals(1, back.deviceIndex)
        assertEquals(0, back.subId)
        assertEquals(0x1A, back.address)
        assertEquals(1, back.function)
        assertEquals(0x0A, back.softwareId)
        assertArrayEquals(byteArrayOf(0, 0, 0x5A), back.params)
    }

    @Test
    fun `long report is zero padded to 20 bytes`() {
        val f = HidppFrame.build(ReportType.LONG, 0xFF, 0x05, 0x11, byteArrayOf(7))
        val bytes = f.encode()
        assertEquals(20, bytes.size)
        assertEquals(0x11, bytes[0].toInt())
        assertEquals(0xFF, bytes[1].toInt() and 0xFF)
        assertEquals(7, bytes[4].toInt())
        assertTrue(bytes.drop(5).all { it.toInt() == 0 })
    }

    @Test
    fun `stripped BLE payload decodes by length`() {
        val stripped = HidppFrame.build(ReportType.LONG, 0xFF, 0x02, 0x0B).encode(withReportId = false)
        assertEquals(19, stripped.size)
        val f = HidppFrame.decode(stripped)!!
        assertEquals(ReportType.LONG, f.type)
        assertEquals(0xFF, f.deviceIndex)
        assertEquals(0x02, f.subId)
    }

    @Test
    fun `garbage does not decode`() {
        assertNull(HidppFrame.decode(byteArrayOf()))
        assertNull(HidppFrame.decode(byteArrayOf(0x10, 1, 2)))
        assertNull(HidppFrame.decode(ByteArray(9)))
    }

    @Test
    fun `error reports are recognised`() {
        val e20 = HidppFrame.build(ReportType.SHORT, 1, 0xFF, 0x03, byteArrayOf(0x1A, Hidpp20Error.UNSUPPORTED.toByte()))
        assertTrue(e20.isHidpp20Error)
        val e10 = HidppFrame.build(ReportType.SHORT, 1, 0x8F, 0x81, byteArrayOf(0xB5.toByte(), Hidpp10Error.UNKNOWN_DEVICE.toByte()))
        assertTrue(e10.isHidpp10Error)
    }

    @Test
    fun `smallest report type honours transport support`() {
        assertEquals(ReportType.SHORT, ReportType.smallestFor(3, ReportType.entries.toSet()))
        assertEquals(ReportType.LONG, ReportType.smallestFor(4, ReportType.entries.toSet()))
        assertEquals(ReportType.LONG, ReportType.smallestFor(1, setOf(ReportType.LONG)))
    }
}
