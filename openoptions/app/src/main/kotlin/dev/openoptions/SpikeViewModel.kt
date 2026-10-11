package dev.openoptions

import android.annotation.SuppressLint
import android.app.Application
import android.app.PendingIntent
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
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
import dev.openoptions.hidpp.Hidpp10Exception
import dev.openoptions.hidpp.HidppChannel
import dev.openoptions.hidpp.HidppTimeoutException
import dev.openoptions.hidpp.ProbeResult
import dev.openoptions.transport.BleHidppTransport
import dev.openoptions.transport.UsbHidppTransport
import kotlinx.coroutines.Job
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
        val adapter = (getApplication<Application>().getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        val bonded = adapter?.bondedDevices?.toList().orEmpty()
            .sortedBy { it.name ?: it.address }
        _state.update { it.copy(bondedDevices = bonded) }
        log("ble: ${bonded.size} bonded device(s)")
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
        // Framing experiment: first without the report ID byte, then with it.
        for (withId in listOf(false, true)) {
            transport.sendReportId = withId
            log("ble probing with sendReportId=$withId")
            val ok = probeIndices(listOf(HidppChannel.DIRECT_DEVICE_INDEX))
            if (ok) { log("ble framing that works: sendReportId=$withId"); return@runBusy }
        }
        log("ble: no response with either framing — capture the log and report it")
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
