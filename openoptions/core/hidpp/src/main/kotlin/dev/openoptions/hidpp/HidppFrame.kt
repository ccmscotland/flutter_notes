package dev.openoptions.hidpp

/** HID++ report types. [length] includes the report ID byte. */
enum class ReportType(val id: Int, val length: Int) {
    SHORT(0x10, 7),
    LONG(0x11, 20),
    VERY_LONG(0x20, 64);

    /** Number of parameter bytes after the two header bytes (sub-id/feature index and address/function). */
    val paramLength: Int get() = length - 4

    companion object {
        fun fromId(id: Int): ReportType? = entries.firstOrNull { it.id == id }

        /** Report type for a payload that has had its report ID stripped (as on BLE). */
        fun fromStrippedLength(len: Int): ReportType? = entries.firstOrNull { it.length - 1 == len }

        /** Smallest report type that can carry [paramCount] parameter bytes, among [allowed]. */
        fun smallestFor(paramCount: Int, allowed: Set<ReportType>): ReportType =
            entries.filter { it in allowed && it.paramLength >= paramCount }.minByOrNull { it.length }
                ?: throw IllegalArgumentException("No allowed report type can carry $paramCount parameter bytes")
    }
}

/**
 * One HID++ report.
 *
 * Layout on the wire: `[reportId][deviceIndex][subId | featureIndex][address | (function << 4 | swId)][params...]`.
 * [body] is everything after the device index, so `body[0]` is the sub-id / feature index and `body[1]` the
 * address / function byte.
 */
class HidppFrame(val type: ReportType, val deviceIndex: Int, val body: ByteArray) {

    init {
        require(body.size == type.length - 2) { "Body for ${type.name} must be ${type.length - 2} bytes, got ${body.size}" }
        require(deviceIndex in 0..0xFF) { "Device index out of range: $deviceIndex" }
    }

    val subId: Int get() = body[0].toInt() and 0xFF
    val address: Int get() = body[1].toInt() and 0xFF
    val params: ByteArray get() = body.copyOfRange(2, body.size)

    val isHidpp20Error: Boolean get() = subId == 0xFF
    val isHidpp10Error: Boolean get() = subId == 0x8F

    /** HID++ 2.0 function (upper nibble of the address byte). */
    val function: Int get() = address shr 4

    /** HID++ 2.0 software id (lower nibble of the address byte). */
    val softwareId: Int get() = address and 0x0F

    fun encode(withReportId: Boolean = true): ByteArray {
        val out = ByteArray(if (withReportId) type.length else type.length - 1)
        var i = 0
        if (withReportId) out[i++] = type.id.toByte()
        out[i++] = deviceIndex.toByte()
        body.copyInto(out, i)
        return out
    }

    override fun toString(): String = "${type.name}[dev=${deviceIndex.hex()} ${body.hex()}]"

    companion object {
        /** Builds a frame, zero-padding [params] to the report length. */
        fun build(type: ReportType, deviceIndex: Int, subId: Int, address: Int, params: ByteArray = ByteArray(0)): HidppFrame {
            require(params.size <= type.paramLength) { "${params.size} params do not fit in ${type.name}" }
            val body = ByteArray(type.length - 2)
            body[0] = subId.toByte()
            body[1] = address.toByte()
            params.copyInto(body, 2)
            return HidppFrame(type, deviceIndex, body)
        }

        /**
         * Decodes a report that may or may not start with its report ID (BLE strips it).
         * Returns null for anything that is not a well-formed HID++ report.
         */
        fun decode(bytes: ByteArray): HidppFrame? {
            if (bytes.isEmpty()) return null
            val withId = ReportType.fromId(bytes[0].toInt() and 0xFF)
            if (withId != null && bytes.size == withId.length) {
                return HidppFrame(withId, bytes[1].toInt() and 0xFF, bytes.copyOfRange(2, bytes.size))
            }
            val stripped = ReportType.fromStrippedLength(bytes.size) ?: return null
            return HidppFrame(stripped, bytes[0].toInt() and 0xFF, bytes.copyOfRange(1, bytes.size))
        }
    }
}

internal fun Int.hex(): String = "%02X".format(this and 0xFF)
fun ByteArray.hex(): String = joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }
internal fun Byte.u(): Int = toInt() and 0xFF
