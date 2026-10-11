package dev.openoptions

import android.annotation.SuppressLint
import android.app.Application
import android.app.PendingIntent
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.openoptions.hidpp.DeviceProbe
import dev.openoptions.hidpp.HidppFrame
import dev.openoptions.hidpp.ReportType
import dev.openoptions.hidpp.hex
import dev.openoptions.hidpp.Hidpp10Exception
import dev.openoptions.hidpp.HidppChannel
import dev.openoptions.hidpp.HidppTimeoutException
import dev.openoptions.hidpp.ProbeResult
import dev.openoptions.transport.BleHidppTransport
import dev.openoptions.transport.UsbHidppTransport
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class SpikeState(
    val usbDevices: List<UsbDevice> = emptyList(),
    val bondedDevices: List<BluetoothDevice> = emptyList(),
    /** Addresses the system currently holds a GATT connection to (the live Easy-Switch slot of each device). */
    val connectedAddresses: Set<String> = emptySet(),
    val connection: String? = null,
    val busy: Boolean = false,
    val results: List<ProbeResult> = emptyList(),
    val log: List<String> = emptyList(),
)

@SuppressLint("MissingPermission")
class SpikeViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow(SpikeState())
    val state: StateFlow<SpikeState> = _state

    private val usbManager = app.getSystemService(Context.USB_SERVICE) as UsbManager
    private var channel: HidppChannel? = null
    private var traceJob: Job? = null

    private val usbPermissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_USB_PERMISSION) return
            val device = IntentCompat.getParcelableExtra(intent, UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            log("usb permission ${if (granted) "granted" else "denied"} for ${device?.deviceName}")
            if (granted && device != null) connectUsb(device)
        }
    }

    init {
        ContextCompat.registerReceiver(app, usbPermissionReceiver, IntentFilter(ACTION_USB_PERMISSION), ContextCompat.RECEIVER_NOT_EXPORTED)
        refreshUsb()
        log("spike ready — plug in a receiver (OTG) or bond a Logitech BLE device in system settings")
    }

    fun log(line: String) {
        val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
        _state.update { it.copy(log = (it.log + "$stamp $line").takeLast(500)) }
    }

    fun refreshUsb() {
        val devices = usbManager.deviceList.values.filter { it.vendorId == UsbHidppTransport.LOGITECH_VENDOR_ID }
        _state.update { it.copy(usbDevices = devices) }
        log("usb: ${devices.size} Logitech device(s) attached")
        devices.forEach { d ->
            log("  ${UsbHidppTransport.describe(d)} permission=${usbManager.hasPermission(d)}")
            UsbHidppTransport.candidates(d).forEach { c ->
                log("    HID intf ${c.intf.id}: IN max ${c.epIn.maxPacketSize}, OUT ${if (c.epOut != null) "yes" else "no"}")
            }
        }
    }

    fun refreshBonded() {
        val manager = getApplication<Application>().getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val connected = manager.getConnectedDevices(BluetoothProfile.GATT).map { it.address }.toSet()
        // A device bonded on several Easy-Switch channels shows up once per channel address; only the
        // channel currently in use answers, the rest fail with status 147 after a 10 s timeout.
        val bonded = manager.adapter?.bondedDevices?.toList().orEmpty()
            .sortedWith(compareBy({ it.address !in connected }, { it.name ?: it.address }))
        _state.update { it.copy(bondedDevices = bonded, connectedAddresses = connected) }
        log("ble: ${bonded.size} bonded device(s), ${connected.size} connected: ${connected.joinToString()}")
    }

    fun requestUsbPermissionAndConnect(device: UsbDevice) {
        if (usbManager.hasPermission(device)) { connectUsb(device); return }
        val app = getApplication<Application>()
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(app.packageName)
        val pi = PendingIntent.getBroadcast(app, 0, intent, PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        log("usb requesting permission for ${device.deviceName}")
        usbManager.requestPermission(device, pi)
    }

    fun connectUsb(device: UsbDevice) = runBusy {
        disconnect()
        val transport = UsbHidppTransport.open(usbManager, device, ::log)
        attach(HidppChannel(transport, viewModelScope), transport.description)
        probeIndices(listOf(HidppChannel.RECEIVER_INDEX, 1, 2, 3, 4, 5, 6))
    }

    fun connectBle(device: BluetoothDevice) = runBusy {
        disconnect()
        val transport = BleHidppTransport(getApplication<Application>(), device, ::log)
        transport.connect()
        val ch = HidppChannel(transport, viewModelScope, timeoutMs = 4_000)
        attach(ch, transport.description)
        // Known-good layout (confirmed on MX Keys Mini): body only, write request.
        transport.framing = BleHidppTransport.Framing.PAYLOAD_ONLY
        transport.writeWithoutResponse = false
        if (probeIndices(listOf(HidppChannel.DIRECT_DEVICE_INDEX))) return@runBusy
        log("ble: default framing got no reply, running the framing experiment")
        val found = bleFramingExperiment(transport)
        if (found == null) {
            log("ble: no framing produced a reply — copy this log and report it")
            return@runBusy
        }
        transport.framing = found.first
        transport.writeWithoutResponse = found.second
        log("ble framing that works: ${found.first.label}, ${if (found.second) "write command" else "write request"}")
        probeIndices(listOf(HidppChannel.DIRECT_DEVICE_INDEX))
    }

    /**
     * Writes a Root.ping in every candidate layout until the device answers. Returns the (framing, write
     * without response) pair that produced a reply, or null.
     */
    private suspend fun bleFramingExperiment(transport: BleHidppTransport): Pair<BleHidppTransport.Framing, Boolean>? {
        runCatching { transport.readValue() }
            .onSuccess { (status, value) -> log("ble read before writing: ${BleHidppTransport.gattStatusName(status)} ${value.hex()} (${value.size} bytes)") }
            .onFailure { log("ble read before writing failed: ${it.message}") }
        val candidates = buildList {
            for (type in listOf(ReportType.LONG, ReportType.SHORT)) {
                for (framing in BleHidppTransport.Framing.entries) {
                    for (noResponse in listOf(false, true)) add(Triple(type, framing, noResponse))
                }
            }
        }
        for ((type, framing, noResponse) in candidates) {
            val ping = HidppFrame.build(type, HidppChannel.DIRECT_DEVICE_INDEX, 0x00, 0x1A, byteArrayOf(0, 0, 0x5A))
            val bytes = ping.encode(withReportId = framing.reportId, withDeviceIndex = framing.deviceIndex)
            val mode = if (noResponse) "write command" else "write request"
            val reply = CompletableDeferred<ByteArray>()
            val listener = viewModelScope.launch { transport.rawIncoming.collect { if (!reply.isCompleted) reply.complete(it) } }
            try {
                val status = transport.writeRaw(bytes, noResponse)
                log("ble try ${type.name} ${framing.label} via $mode: ${bytes.size} bytes → ${BleHidppTransport.gattStatusName(status)}")
                if (status != 0) continue
                val value = withTimeoutOrNull(1_500) { reply.await() }
                if (value != null) {
                    log("ble reply (${value.size} bytes): ${value.hex()}")
                    return framing to noResponse
                }
                runCatching { transport.readValue() }
                    .onSuccess { (st, v) -> log("ble read after write: ${BleHidppTransport.gattStatusName(st)} ${v.hex()}") }
                log("ble no notification within 1.5 s")
            } catch (e: Exception) {
                log("ble try ${type.name} ${framing.label} via $mode failed: ${e.message}")
            } finally {
                listener.cancel()
            }
        }
        return null
    }

    /** Probes each index; returns true when at least one answered. */
    private suspend fun probeIndices(indices: List<Int>): Boolean {
        val ch = channel ?: return false
        var any = false
        for (index in indices) {
            try {
                val r = DeviceProbe.probe(ch, index)
                any = true
                log("probe ${r.summary()}")
                r.features.forEach { f -> log("    feature[${f.index}] ${f.name} v${f.version}${if (f.isHidden) " (hidden)" else ""}") }
                _state.update { s -> s.copy(results = s.results.filter { it.deviceIndex != index } + r) }
            } catch (e: Hidpp10Exception) {
                log("probe [%02X] %s".format(index, e.message))
            } catch (e: HidppTimeoutException) {
                log("probe [%02X] no response".format(index))
            } catch (e: Exception) {
                log("probe [%02X] failed: %s".format(index, e))
            }
        }
        return any
    }

    private fun attach(ch: HidppChannel, label: String) {
        channel = ch
        _state.update { it.copy(connection = label, results = emptyList()) }
        traceJob = viewModelScope.launch {
            ch.trace.collect { (dir, frame) -> log("${if (dir == HidppChannel.Direction.OUT) "→" else "←"} $frame") }
        }
        log("connected: $label")
    }

    fun disconnect() {
        traceJob?.cancel(); traceJob = null
        channel?.let { runCatching { it.close() }; log("disconnected") }
        channel = null
        _state.update { it.copy(connection = null) }
    }

    fun logText(): String = _state.value.log.joinToString("\n")

    private fun runBusy(block: suspend () -> Unit) {
        if (_state.value.busy) { log("busy — wait for the current operation"); return }
        viewModelScope.launch {
            _state.update { it.copy(busy = true) }
            try { block() } catch (e: Exception) { log("error: $e"); disconnect() } finally { _state.update { it.copy(busy = false) } }
        }
    }

    override fun onCleared() {
        disconnect()
        runCatching { getApplication<Application>().unregisterReceiver(usbPermissionReceiver) }
    }

    companion object {
        const val ACTION_USB_PERMISSION = "dev.openoptions.USB_PERMISSION"
    }
}
