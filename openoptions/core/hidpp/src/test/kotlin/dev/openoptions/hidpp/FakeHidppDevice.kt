package dev.openoptions.hidpp

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * A scripted HID++ endpoint for tests: a receiver at index 0xFF with one or more HID++ 2.0 devices behind it,
 * or a direct device at 0xFF when [direct] is true.
 */
class FakeHidppDevice(
    private val direct: Boolean = false,
    override val supportedReports: Set<ReportType> = if (direct) setOf(ReportType.LONG) else ReportType.entries.toSet(),
) : HidppTransport {

    class Device(
        val name: String,
        val type: Int,
        val features: List<Int>,                // feature ids in index order (index 1..n)
        val battery: ByteArray? = null,         // UnifiedBattery.getStatus params
        val legacyBattery: ByteArray? = null,   // BatteryStatus params
        val firmware: List<ByteArray> = emptyList(),
        val protocol: ProtocolVersion = ProtocolVersion(4, 5),
    ) {
        // Mutable settings state so set/read round-trips can be tested.
        var dpi = 1000
        var dpiList: ByteArray = byteArrayOf(0x00, 0x00, 0x64, 0xE0.toByte(), 0x32, 0x0F, 0xA0.toByte(), 0x00, 0x00) // 100, step 50, ..., 4000
        var smartShiftMode = 2
        var smartShiftThreshold = 20
        var wheelMode = 0x02
        var thumbDivert = 0
        var thumbInvert = 0
        var backlightEnabled = 1
        var backlightOptions = 0x18 // mode 3 (manual)
        var backlightLevel = 2
        var backlightDurations = intArrayOf(12, 6, 60) // 5-second units
        var fnInverted = IntArray(3)
        var currentHost = 1
        var hostNames = arrayOf("Desk PC", "", "Laptop")
        val reporting = HashMap<Int, ByteArray>()
        var lastChangeHost = -1
        val controls = listOf(
            intArrayOf(0x0050, 0x0038, 0x01, 0, 1, 0x01, 0x00),
            intArrayOf(0x0053, 0x003A, 0x71, 0, 1, 0x01, 0x01),
            intArrayOf(0x00C3, 0x00B2, 0x71, 0, 1, 0x01, 0x03),
        )
    }

    val devices = HashMap<Int, Device>()
    val written = ArrayList<HidppFrame>()
    private val flow = MutableSharedFlow<HidppFrame>(extraBufferCapacity = 64)
    override val incoming: Flow<HidppFrame> = flow
    override val description = "fake"
    var dropNext = false
    var respondWithShort = false

    fun emit(frame: HidppFrame) { check(flow.tryEmit(frame)) }

    override suspend fun write(frame: HidppFrame) {
        written += frame
        if (dropNext) { dropNext = false; return }
        reply(frame)?.let { emit(it) }
    }

    private fun reply(req: HidppFrame): HidppFrame? {
        val idx = req.deviceIndex
        val device = devices[idx]
        if (device == null) {
            // Receiver itself, or an empty slot: HID++ 1.0 error semantics.
            val code = if (idx == 0xFF && !direct) Hidpp10Error.INVALID_SUBID else Hidpp10Error.UNKNOWN_DEVICE
            return HidppFrame.build(ReportType.SHORT, idx, 0x8F, req.subId, byteArrayOf(req.address.toByte(), code.toByte()))
        }
        val featureIndex = req.subId
        val fn = req.function
        val p = req.params
        val featureId = if (featureIndex == 0) Features.ROOT else device.features.getOrNull(featureIndex - 1)
            ?: return error20(req, Hidpp20Error.INVALID_FEATURE_INDEX)
        val out: ByteArray = when (featureId) {
            Features.ROOT -> when (fn) {
                0 -> { val id = (p[0].u() shl 8) or p[1].u(); val i = device.features.indexOf(id); byteArrayOf(if (i < 0) 0 else (i + 1).toByte(), 0, 0) }
                1 -> byteArrayOf(device.protocol.major.toByte(), device.protocol.minor.toByte(), p[2])
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.FEATURE_SET -> when (fn) {
                0 -> byteArrayOf(device.features.size.toByte())
                1 -> { val id = device.features[p[0].u() - 1]; byteArrayOf((id shr 8).toByte(), id.toByte(), 0, 1) }
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.DEVICE_NAME -> when (fn) {
                0 -> byteArrayOf(device.name.length.toByte())
                1 -> device.name.drop(p[0].u()).take(16).toByteArray(Charsets.US_ASCII)
                2 -> byteArrayOf(device.type.toByte())
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.DEVICE_FW_VERSION -> when (fn) {
                0 -> byteArrayOf(device.firmware.size.toByte())
                1 -> device.firmware[p[0].u()]
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.UNIFIED_BATTERY -> when (fn) {
                1 -> device.battery ?: return error20(req, Hidpp20Error.UNSUPPORTED)
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.BATTERY_STATUS -> when (fn) {
                0 -> device.legacyBattery ?: return error20(req, Hidpp20Error.UNSUPPORTED)
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.ADJUSTABLE_DPI -> when (fn) {
                0 -> byteArrayOf(1)
                1 -> device.dpiList
                2 -> byteArrayOf(0, (device.dpi shr 8).toByte(), device.dpi.toByte(), 0x03, 0xE8.toByte())
                3 -> { device.dpi = (p[1].u() shl 8) or p[2].u(); p.copyOf(3) }
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.SMART_SHIFT_ENHANCED -> when (fn) {
                0 -> byteArrayOf(0x01, 0x14)
                1 -> byteArrayOf(device.smartShiftMode.toByte(), device.smartShiftThreshold.toByte(), 0x14)
                2 -> { if (p[0].u() != 0) device.smartShiftMode = p[0].u(); if (p[1].u() != 0) device.smartShiftThreshold = p[1].u(); p.copyOf(3) }
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.HIRES_WHEEL -> when (fn) {
                0 -> byteArrayOf(0x08, 0x0C, 24, 0)
                1 -> byteArrayOf(device.wheelMode.toByte(), 0)
                2 -> { device.wheelMode = p[0].u(); byteArrayOf(p[0], 0) }
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.THUMB_WHEEL -> when (fn) {
                1 -> byteArrayOf(device.thumbDivert.toByte(), device.thumbInvert.toByte())
                2 -> { device.thumbDivert = p[0].u(); device.thumbInvert = p[1].u(); p.copyOf(2) }
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.BACKLIGHT_V2 -> when (fn) {
                0 -> byteArrayOf(
                    device.backlightEnabled.toByte(), device.backlightOptions.toByte(), 0x38, 0x01, 0x00, device.backlightLevel.toByte(),
                    device.backlightDurations[0].toByte(), (device.backlightDurations[0] shr 8).toByte(),
                    device.backlightDurations[1].toByte(), (device.backlightDurations[1] shr 8).toByte(),
                    device.backlightDurations[2].toByte(), (device.backlightDurations[2] shr 8).toByte(),
                )
                1 -> {
                    device.backlightEnabled = p[0].u(); device.backlightOptions = p[1].u()
                    if ((p[1].u() shr 3) and 3 == 3) device.backlightLevel = p[3].u()
                    device.backlightDurations = intArrayOf(p[4].u() or (p[5].u() shl 8), p[6].u() or (p[7].u() shl 8), p[8].u() or (p[9].u() shl 8))
                    p.copyOf(10)
                }
                2 -> byteArrayOf(4, device.backlightLevel.toByte(), 0, 0)
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.K375S_FN_INVERSION -> when (fn) {
                0 -> byteArrayOf(p[0], device.fnInverted[p[0].u()].toByte(), 0)
                1 -> { device.fnInverted[p[0].u()] = p[1].u(); byteArrayOf(p[0], p[1]) }
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.HOSTS_INFO -> when (fn) {
                0 -> byteArrayOf(0x03, 0x00, 3, device.currentHost.toByte())
                1 -> { val h = p[0].u(); val n = device.hostNames[h]; byteArrayOf(h.toByte(), if (n.isEmpty()) 0 else 1, 1, 0, n.length.toByte(), 24) }
                3 -> { val h = p[0].u(); val off = p[1].u(); byteArrayOf(h.toByte(), off.toByte()) + device.hostNames[h].drop(off).take(14).toByteArray() }
                4 -> { val h = p[0].u(); val off = p[1].u(); val chunk = String(p.copyOfRange(2, p.size)).trimEnd('\u0000'); device.hostNames[h] = device.hostNames[h].take(off) + chunk; byteArrayOf(h.toByte(), device.hostNames[h].length.toByte()) }
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.CHANGE_HOST -> when (fn) {
                0 -> byteArrayOf(3, device.currentHost.toByte(), 0)
                1 -> { device.lastChangeHost = p[0].u(); return null } // device switches away, no reply
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            Features.REPROG_CONTROLS_V4 -> when (fn) {
                0 -> byteArrayOf(device.controls.size.toByte())
                1 -> { val c = device.controls[p[0].u()]; byteArrayOf((c[0] shr 8).toByte(), c[0].toByte(), (c[1] shr 8).toByte(), c[1].toByte(), c[2].toByte(), c[3].toByte(), c[4].toByte(), c[5].toByte(), c[6].toByte()) }
                2 -> { val cid = (p[0].u() shl 8) or p[1].u(); val st = device.reporting[cid] ?: byteArrayOf(0, 0, 0); byteArrayOf(p[0], p[1]) + st }
                3 -> {
                    val cid = (p[0].u() shl 8) or p[1].u()
                    val st = device.reporting[cid] ?: byteArrayOf(0, 0, 0)
                    var flags = st[0].u()
                    val f = p[2].u()
                    for (bit in listOf(0x01, 0x04, 0x10)) if (f and (bit shl 1) != 0) flags = if (f and bit != 0) flags or bit else flags and bit.inv()
                    val remap = if (p[3].u() == 0 && p[4].u() == 0) st.copyOfRange(1, 3) else byteArrayOf(p[3], p[4])
                    device.reporting[cid] = byteArrayOf(flags.toByte()) + remap
                    p.copyOf(5)
                }
                else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
            }
            else -> return error20(req, Hidpp20Error.INVALID_FUNCTION_ID)
        }
        val type = if (respondWithShort && out.size <= 3 && ReportType.SHORT in supportedReports) ReportType.SHORT else ReportType.LONG
        return HidppFrame.build(type, idx, featureIndex, req.address, out)
    }

    private fun error20(req: HidppFrame, code: Int): HidppFrame =
        HidppFrame.build(ReportType.SHORT, req.deviceIndex, 0xFF, req.subId, byteArrayOf(req.address.toByte(), code.toByte()))

    override fun close() {}

    companion object {
        fun mxMaster3s(): Device = Device(
            name = "MX Master 3S",
            type = 3,
            features = listOf(
                Features.FEATURE_SET, Features.DEVICE_FW_VERSION, Features.DEVICE_NAME, Features.UNIFIED_BATTERY,
                Features.REPROG_CONTROLS_V4, Features.ADJUSTABLE_DPI, Features.SMART_SHIFT_ENHANCED, Features.HIRES_WHEEL,
                Features.THUMB_WHEEL, Features.CHANGE_HOST, Features.HOSTS_INFO,
            ),
            battery = byteArrayOf(72, 0x04, 0x00, 0x00),
            firmware = listOf(
                byteArrayOf(0, 'M'.code.toByte(), 'P'.code.toByte(), 'M'.code.toByte(), 0x26, 0x01, 0x00, 0x1A, 0x01, 0xB0.toByte(), 0x34),
                byteArrayOf(1, 'B'.code.toByte(), 'L'.code.toByte(), '1'.code.toByte(), 0x01, 0x07, 0x00, 0x05, 0x00, 0xB0.toByte(), 0x34),
            ),
        )

        fun mxKeys(): Device = Device(
            name = "MX Keys",
            type = 0,
            features = listOf(
                Features.FEATURE_SET, Features.DEVICE_FW_VERSION, Features.DEVICE_NAME, Features.BATTERY_STATUS,
                Features.K375S_FN_INVERSION, Features.BACKLIGHT_V2, Features.HOSTS_INFO, Features.CHANGE_HOST, Features.REPROG_CONTROLS_V4,
            ),
            legacyBattery = byteArrayOf(50, 30, 0),
        )
    }
}
