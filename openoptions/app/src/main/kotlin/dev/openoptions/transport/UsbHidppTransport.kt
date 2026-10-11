package dev.openoptions.transport

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import dev.openoptions.hidpp.HidppFrame
import dev.openoptions.hidpp.HidppTransport
import dev.openoptions.hidpp.ReportType
import dev.openoptions.hidpp.hex
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.withContext
import java.io.IOException
import kotlin.concurrent.thread

/**
 * HID++ over a USB receiver (Unifying, Bolt, Nano) or a wired Logitech device, via the Android USB host API.
 *
 * Only the vendor HID++ interface is claimed; the keyboard and mouse interfaces stay with the system so input
 * keeps working while the app is connected.
 */
class UsbHidppTransport private constructor(
    private val connection: UsbDeviceConnection,
    private val intf: UsbInterface,
    private val epIn: UsbEndpoint,
    private val epOut: UsbEndpoint?,
    override val description: String,
    private val log: (String) -> Unit,
) : HidppTransport {

    override val supportedReports: Set<ReportType> = setOf(ReportType.SHORT, ReportType.LONG, ReportType.VERY_LONG)

    private val _incoming = MutableSharedFlow<HidppFrame>(extraBufferCapacity = 128)
    override val incoming: Flow<HidppFrame> = _incoming

    @Volatile
    private var running = true

    private val reader = thread(name = "hidpp-usb-reader", isDaemon = true) {
        val buf = ByteArray(maxOf(epIn.maxPacketSize, 64))
        while (running) {
            val n = connection.bulkTransfer(epIn, buf, buf.size, READ_TIMEOUT_MS)
            if (n <= 0) continue
            val bytes = buf.copyOf(n)
            val frame = HidppFrame.decode(bytes)
            if (frame == null) {
                log("usb ← unparsed ${bytes.hex()}")
            } else if (!_incoming.tryEmit(frame)) {
                log("usb ← dropped (buffer full) $frame")
            }
        }
    }

    override suspend fun write(frame: HidppFrame) = withContext(Dispatchers.IO) {
        val bytes = frame.encode()
        val n = if (epOut != null) {
            connection.bulkTransfer(epOut, bytes, bytes.size, WRITE_TIMEOUT_MS)
        } else {
            // HID class SET_REPORT, report type Output (2), report id in the low byte of wValue.
            connection.controlTransfer(
                UsbConstants.USB_TYPE_CLASS or UsbConstants.USB_DIR_OUT or 0x01, // recipient: interface
                HID_SET_REPORT,
                (HID_REPORT_TYPE_OUTPUT shl 8) or frame.type.id,
                intf.id,
                bytes, bytes.size, WRITE_TIMEOUT_MS,
            )
        }
        if (n < 0) throw IOException("USB write failed ($n) for $frame")
    }

    override fun close() {
        running = false
        runCatching { connection.releaseInterface(intf) }
        runCatching { connection.close() }
    }

    companion object {
        const val LOGITECH_VENDOR_ID = 0x046D
        private const val HID_SET_REPORT = 0x09
        private const val HID_REPORT_TYPE_OUTPUT = 0x02
        private const val READ_TIMEOUT_MS = 250
        private const val WRITE_TIMEOUT_MS = 1_000

        data class Candidate(val intf: UsbInterface, val epIn: UsbEndpoint, val epOut: UsbEndpoint?)

        /** HID interfaces with an interrupt IN endpoint, largest packet first (the HID++ interface on a receiver). */
        fun candidates(device: UsbDevice): List<Candidate> =
            (0 until device.interfaceCount).map(device::getInterface)
                .filter { it.interfaceClass == UsbConstants.USB_CLASS_HID }
                .mapNotNull { intf ->
                    val eps = (0 until intf.endpointCount).map(intf::getEndpoint)
                    val input = eps.firstOrNull { it.direction == UsbConstants.USB_DIR_IN && it.type == UsbConstants.USB_ENDPOINT_XFER_INT }
                        ?: return@mapNotNull null
                    val output = eps.firstOrNull { it.direction == UsbConstants.USB_DIR_OUT && it.type == UsbConstants.USB_ENDPOINT_XFER_INT }
                    Candidate(intf, input, output)
                }
                .sortedByDescending { it.epIn.maxPacketSize }

        fun describe(device: UsbDevice): String = buildString {
            append("USB %04X:%04X".format(device.vendorId, device.productId))
            device.productName?.let { append(" \"$it\"") }
            append(" @ ${device.deviceName}")
        }

        /**
         * Opens [device] and claims [candidate] (defaults to the best candidate). Throws [IOException] when the
         * kernel refuses to hand over the interface, which is the OEM limitation the spike is meant to surface.
         */
        fun open(manager: UsbManager, device: UsbDevice, log: (String) -> Unit, candidate: Candidate? = null): UsbHidppTransport {
            val chosen = candidate ?: candidates(device).firstOrNull()
                ?: throw IOException("No HID interface with an interrupt IN endpoint on ${describe(device)}")
            val connection = manager.openDevice(device) ?: throw IOException("openDevice returned null (permission?)")
            if (!connection.claimInterface(chosen.intf, true)) {
                connection.close()
                throw IOException("claimInterface(force=true) refused for interface ${chosen.intf.id} — this phone's kernel keeps HID interfaces")
            }
            log("usb claimed interface ${chosen.intf.id} (IN ep ${chosen.epIn.address.hex()} max ${chosen.epIn.maxPacketSize}, OUT ${chosen.epOut?.address?.hex() ?: "none"})")
            return UsbHidppTransport(connection, chosen.intf, chosen.epIn, chosen.epOut, describe(device), log)
        }
    }
}

private fun Int.hex(): String = "%02X".format(this and 0xFF)
