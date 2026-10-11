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
 * [sendReportId] selects the outgoing framing, and incoming values are decoded either way.
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

    @Volatile
    var sendReportId: Boolean = false

    private var gatt: BluetoothGatt? = null
    private var hidppChar: BluetoothGattCharacteristic? = null
    private val ready = CompletableDeferred<Unit>()
    private val writeMutex = Mutex()

    @Volatile
    private var writeAck: CompletableDeferred<Int>? = null

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            log("ble connection state=$newState status=$status")
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
            log("ble CCCD write status=$status")
            if (status == BluetoothGatt.GATT_SUCCESS) ready.complete(Unit)
            else ready.completeExceptionally(IOException("CCCD write failed status=$status (insufficient authentication = not bonded?)"))
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            writeAck?.complete(status)
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
        val frame = HidppFrame.decode(value)
        if (frame == null) {
            log("ble ← unparsed ${value.hex()}")
        } else if (!_incoming.tryEmit(frame)) {
            log("ble ← dropped $frame")
        }
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

    override suspend fun write(frame: HidppFrame) = writeMutex.withLock {
        val g = gatt ?: throw IOException("Not connected")
        val c = hidppChar ?: throw IOException("Not connected")
        val bytes = frame.encode(withReportId = sendReportId)
        val ack = CompletableDeferred<Int>()
        writeAck = ack
        val writeType = if (c.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0)
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(c, bytes, writeType) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run { c.writeType = writeType; c.value = bytes; g.writeCharacteristic(c) }
        }
        if (!started) { writeAck = null; throw IOException("writeCharacteristic refused for $frame") }
        val status = withTimeoutOrNull(2_000) { ack.await() }
        writeAck = null
        if (status == null) throw IOException("No write acknowledgement for $frame")
        if (status != BluetoothGatt.GATT_SUCCESS) throw IOException("GATT write status $status for $frame")
    }

    override fun close() {
        gatt?.let { runCatching { it.disconnect() }; runCatching { it.close() } }
        gatt = null
    }

    companion object {
        val HIDPP_SERVICE: UUID = UUID.fromString("00010000-0000-1000-8000-011F2000046D")
        val HIDPP_CHARACTERISTIC: UUID = UUID.fromString("00010001-0000-1000-8000-011F2000046D")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
    }
}
