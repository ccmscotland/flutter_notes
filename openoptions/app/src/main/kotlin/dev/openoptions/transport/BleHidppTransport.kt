package dev.openoptions.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import dev.openoptions.hidpp.HidppFrame
import dev.openoptions.hidpp.HidppTransport
import dev.openoptions.hidpp.ReportType
import dev.openoptions.hidpp.hex
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.util.UUID

/**
 * HID++ over Logitech's vendor GATT service on a directly bonded BLE device.
 *
 * Android refuses third-party access to the standard HID service (0x1812), so this is the only BLE path open to
 * an app. The device must already be bonded in system Bluetooth settings.
 *
 * Whether the characteristic value carries the report ID byte is one of the questions the spike answers:
 * [framing] and [writeWithoutResponse] select the outgoing layout; incoming values are decoded whatever their layout.
 */
@SuppressLint("MissingPermission")
class BleHidppTransport(
    private val context: Context,
    private val device: BluetoothDevice,
    private val log: (String) -> Unit,
) : HidppTransport {

    override val supportedReports: Set<ReportType> = setOf(ReportType.LONG)
    override val description: String = "BLE ${device.address} \"${device.name ?: "?"}\""

    private val _incoming = MutableSharedFlow<HidppFrame>(extraBufferCapacity = 128)
    override val incoming: Flow<HidppFrame> = _incoming

    /** How a HID++ frame is laid out in the characteristic value. */
    enum class Framing(val label: String, val reportId: Boolean, val deviceIndex: Boolean) {
        PAYLOAD_ONLY("body only (18 bytes for a long report)", reportId = false, deviceIndex = false),
        NO_REPORT_ID("device index + body (19 bytes)", reportId = false, deviceIndex = true),
        FULL_REPORT("report id + device index + body (20 bytes)", reportId = true, deviceIndex = true),
    }

    @Volatile
    var framing: Framing = Framing.PAYLOAD_ONLY

    /** Use ATT Write Command instead of Write Request. The characteristic advertises both. */
    @Volatile
    var writeWithoutResponse: Boolean = false

    /** Every raw characteristic value received, for the framing experiment. */
    private val _rawIncoming = MutableSharedFlow<ByteArray>(extraBufferCapacity = 64)
    val rawIncoming: Flow<ByteArray> = _rawIncoming

    private var gatt: BluetoothGatt? = null
    private var hidppChar: BluetoothGattCharacteristic? = null
    private val ready = CompletableDeferred<Unit>()
    private val writeMutex = Mutex()

    @Volatile
    private var writeAck: CompletableDeferred<Int>? = null

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            log("ble connection state=$newState status=${gattStatusName(status)}")
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                if (!g.requestMtu(64)) g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                ready.completeExceptionally(IOException("GATT disconnected (status $status)"))
                writeAck?.completeExceptionally(IOException("GATT disconnected"))
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            log("ble mtu=$mtu status=$status")
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            log("ble services discovered status=$status")
            for (s in g.services) {
                log("  service ${s.uuid}: ${s.characteristics.joinToString { c -> c.uuid.toString().take(8) + "/props=" + c.properties.toString(16) }}")
            }
            val service = g.getService(HIDPP_SERVICE)
            if (service == null) {
                ready.completeExceptionally(IOException("Vendor HID++ service $HIDPP_SERVICE not found"))
                return
            }
            val c = service.getCharacteristic(HIDPP_CHARACTERISTIC)
                ?: service.characteristics.firstOrNull { it.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0 }
            if (c == null) {
                ready.completeExceptionally(IOException("No notify characteristic in vendor service"))
                return
            }
            hidppChar = c
            log("ble using characteristic ${c.uuid} props=0x${c.properties.toString(16)}")
            g.setCharacteristicNotification(c, true)
            val cccd = c.getDescriptor(CCCD)
            if (cccd == null) {
                log("ble no CCCD descriptor; assuming notifications are on")
                ready.complete(Unit)
                return
            }
            val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run { cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; g.writeDescriptor(cccd) }
            }
            if (!ok) ready.completeExceptionally(IOException("writeDescriptor(CCCD) refused"))
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            log("ble CCCD write status=${gattStatusName(status)}")
            if (status == BluetoothGatt.GATT_SUCCESS) ready.complete(Unit)
            else ready.completeExceptionally(IOException("CCCD write failed status=$status (insufficient authentication = not bonded?)"))
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            writeAck?.complete(status)
        }

        // API 33+
        override fun onCharacteristicRead(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            readAck?.complete(status to value)
        }

        @Deprecated("Deprecated in API 33; kept for API 29-32")
        override fun onCharacteristicRead(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                @Suppress("DEPRECATION")
                readAck?.complete(status to (characteristic.value ?: ByteArray(0)))
            }
        }

        // API 33+
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            onValue(value)
        }

        @Deprecated("Deprecated in API 33; kept for API 29-32")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                @Suppress("DEPRECATION")
                characteristic.value?.let { onValue(it) }
            }
        }
    }

    private fun onValue(value: ByteArray) {
        _rawIncoming.tryEmit(value)
        val frame = HidppFrame.decode(value, implicitDeviceIndex = 0xFF)
        if (frame == null) {
            log("ble ← unparsed (${value.size} bytes) ${value.hex()}")
        } else if (!_incoming.tryEmit(frame)) {
            log("ble ← dropped $frame")
        }
    }

    @Volatile
    private var readAck: CompletableDeferred<Pair<Int, ByteArray>>? = null

    /** Reads the characteristic value directly (it advertises the read property). */
    suspend fun readValue(): Pair<Int, ByteArray> = writeMutex.withLock {
        val g = gatt ?: throw IOException("Not connected")
        val c = hidppChar ?: throw IOException("Not connected")
        val ack = CompletableDeferred<Pair<Int, ByteArray>>()
        readAck = ack
        if (!g.readCharacteristic(c)) { readAck = null; throw IOException("readCharacteristic refused") }
        val r = withTimeoutOrNull(2_000) { ack.await() }
        readAck = null
        r ?: throw IOException("No read response")
    }

    /**
     * Writes [bytes] as-is and returns the GATT status (0 = success). A Write Command has no acknowledgement,
     * so Android reports success as soon as it is queued.
     */
    suspend fun writeRaw(bytes: ByteArray, noResponse: Boolean): Int = writeMutex.withLock {
        val g = gatt ?: throw IOException("Not connected")
        val c = hidppChar ?: throw IOException("Not connected")
        val ack = CompletableDeferred<Int>()
        writeAck = ack
        val writeType = if (noResponse) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(c, bytes, writeType) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run { c.writeType = writeType; c.value = bytes; g.writeCharacteristic(c) }
        }
        if (!started) { writeAck = null; throw IOException("writeCharacteristic refused (${bytes.size} bytes)") }
        val status = withTimeoutOrNull(2_000) { ack.await() }
        writeAck = null
        status ?: throw IOException("No write acknowledgement (${bytes.size} bytes)")
    }

    suspend fun connect(timeoutMs: Long = 20_000) {
        log("ble connecting to $description (bond state ${device.bondState})")
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        try {
            withTimeoutOrNull(timeoutMs) { ready.await() } ?: throw IOException("BLE connect timed out")
        } catch (e: Exception) {
            close()
            throw e
        }
    }

    override suspend fun write(frame: HidppFrame) {
        val f = framing
        val bytes = frame.encode(withReportId = f.reportId, withDeviceIndex = f.deviceIndex)
        val status = writeRaw(bytes, writeWithoutResponse)
        if (status != BluetoothGatt.GATT_SUCCESS) throw IOException("GATT write status ${gattStatusName(status)} for $frame")
    }

    override fun close() {
        gatt?.let { runCatching { it.disconnect() }; runCatching { it.close() } }
        gatt = null
    }

    companion object {
        fun gattStatusName(status: Int): String = when (status) {
            0 -> "SUCCESS"
            1 -> "INVALID_HANDLE"
            2 -> "READ_NOT_PERMITTED"
            3 -> "WRITE_NOT_PERMITTED"
            4 -> "INVALID_PDU"
            5 -> "INSUFFICIENT_AUTHENTICATION"
            6 -> "REQUEST_NOT_SUPPORTED"
            7 -> "INVALID_OFFSET"
            8 -> "INSUFFICIENT_AUTHORIZATION"
            13 -> "INVALID_ATTRIBUTE_LENGTH"
            14 -> "UNLIKELY_ERROR"
            15 -> "INSUFFICIENT_ENCRYPTION"
            133 -> "GATT_ERROR(133)"
            147 -> "CONN_FAIL_ESTABLISH(147)"
            else -> "status $status"
        }

        val HIDPP_SERVICE: UUID = UUID.fromString("00010000-0000-1000-8000-011F2000046D")
        val HIDPP_CHARACTERISTIC: UUID = UUID.fromString("00010001-0000-1000-8000-011F2000046D")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
    }
}
