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
    )

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
                Features.NEW_FN_INVERSION, Features.BACKLIGHT_V2,
            ),
            legacyBattery = byteArrayOf(50, 30, 0),
        )
    }
}
