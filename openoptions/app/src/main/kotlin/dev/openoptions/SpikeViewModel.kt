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
import dev.openoptions.actions.ActionAccessibilityService
import dev.openoptions.actions.ActionRunner
import dev.openoptions.actions.AndroidAction
import dev.openoptions.hidpp.DeviceProbe
import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.features.ControlEvent
import dev.openoptions.hidpp.features.ControlEvents
import dev.openoptions.hidpp.features.DivertedButtonTracker
import dev.openoptions.hidpp.features.ReprogControls
import android.provider.Settings
import kotlinx.coroutines.runBlocking
import dev.openoptions.hidpp.DeviceSettings
import dev.openoptions.hidpp.DeviceSettingsSnapshot
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.features.AdjustableDpi
import dev.openoptions.hidpp.features.Backlight
import dev.openoptions.hidpp.features.FnInversion
import dev.openoptions.hidpp.features.HiResWheel
import dev.openoptions.hidpp.features.Hosts
import dev.openoptions.hidpp.features.SmartShift
import dev.openoptions.hidpp.features.ThumbWheel
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
    /** Settings of the device most recently probed, keyed by its device index. */
    val settingsDeviceIndex: Int? = null,
    val settings: DeviceSettingsSnapshot? = null,
    /** Control id → action for diverted buttons on the current device. */
    val bindings: Map<Int, AndroidAction> = emptyMap(),
    val accessibilityEnabled: Boolean = false,
    val lastButtonEvent: String? = null,
    val log: List<String> = emptyList(),
)

@SuppressLint("MissingPermission")
class SpikeViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow(SpikeState())
    val state: StateFlow<SpikeState> = _state

    private val usbManager = app.getSystemService(Context.USB_SERVICE) as UsbManager
    private var channel: HidppChannel? = null
    private var traceJob: Job? = null
    private var eventJob: Job? = null
    private var reprogFeatureIndex: Int? = null
    private val tracker = DivertedButtonTracker()

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
        teardown()
        val transport = UsbHidppTransport.open(usbManager, device, ::log)
        attach(HidppChannel(transport, viewModelScope), transport.description)
        probeIndices(listOf(HidppChannel.RECEIVER_INDEX, 1, 2, 3, 4, 5, 6))
    }

    fun connectBle(device: BluetoothDevice) = runBusy {
        teardown()
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
                if (!r.protocol.isHidpp10) readSettings(index)
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

    private fun currentDevice(index: Int? = null): Hidpp20Device? {
        val ch = channel ?: return null
        val i = index ?: _state.value.settingsDeviceIndex ?: return null
        return Hidpp20Device(ch, i)
    }

    private suspend fun readSettings(index: Int) {
        val d = currentDevice(index) ?: return
        val snap = DeviceSettings.read(d) { section, e -> log("settings: $section failed: ${e.message}") }
        reprogFeatureIndex = runCatching { d.featureIndex(Features.REPROG_CONTROLS_V4) }.getOrNull()
        _state.update { it.copy(settingsDeviceIndex = index, settings = snap) }
        log("settings read: dpi=${snap.dpi?.current} smartShift=${snap.smartShift} wheel=${snap.wheel} thumb=${snap.thumbWheel} backlight=${snap.backlight} fn=${snap.fnInversion} hosts=${snap.hosts?.hosts?.map { h -> "${h.index}:${h.name ?: "-"}${if (h.isCurrent) "*" else ""}" }} controls=${snap.controls.size}")
        snap.controls.forEach { c -> log("    control ${c.name} cid=0x%04X flags=0x%03X group=%d".format(c.cid, c.flags, c.group)) }
    }

    /** Runs a setter against the current device, then re-reads the settings so the UI shows what the device accepted. */
    private fun applySetting(label: String, block: suspend (Hidpp20Device) -> Unit) = runBusy {
        val d = currentDevice() ?: run { log("$label: not connected"); return@runBusy }
        log("apply $label")
        block(d)
        readSettings(d.deviceIndex)
    }

    fun setDpi(dpi: Int) = applySetting("dpi=$dpi") { AdjustableDpi.set(it, dpi) }
    fun setRatchet(ratchet: Boolean) = applySetting("ratchet=$ratchet") { SmartShift.set(it, ratchet = ratchet) }
    fun setSmartShiftThreshold(t: Int) = applySetting("smartShiftThreshold=$t") { SmartShift.set(it, threshold = t) }
    fun setWheelInverted(v: Boolean) = applySetting("wheelInverted=$v") { HiResWheel.set(it, inverted = v) }
    fun setWheelHighRes(v: Boolean) = applySetting("wheelHighRes=$v") { HiResWheel.set(it, highResolution = v) }
    fun setThumbInverted(v: Boolean) = applySetting("thumbInverted=$v") { ThumbWheel.set(it, inverted = v) }
    fun setFnKeysDefault(v: Boolean) = applySetting("fKeysDefault=$v") { FnInversion.set(it, v) }
    fun setBacklightEnabled(v: Boolean) = applySetting("backlightEnabled=$v") { Backlight.write(it, enabled = v) }
    fun setBacklightMode(mode: Int) = applySetting("backlightMode=$mode") { Backlight.write(it, mode = mode) }
    fun setBacklightLevel(level: Int) = applySetting("backlightLevel=$level") { Backlight.write(it, level = level) }
    fun refreshAccessibilityStatus() {
        _state.update { it.copy(accessibilityEnabled = ActionAccessibilityService.isRunning) }
    }

    fun openAccessibilitySettings() {
        val app = getApplication<Application>()
        runCatching {
            app.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { log("could not open accessibility settings: ${it.message}") }
    }

    /** Diverts [cid] to the app and binds it to [action]; NONE restores the device's own behaviour. */
    fun bind(cid: Int, action: AndroidAction) = runBusy {
        val d = currentDevice() ?: run { log("bind: not connected"); return@runBusy }
        val divert = action != AndroidAction.NONE
        ReprogControls.setReporting(d, cid, diverted = divert)
        val rep = ReprogControls.reporting(d, cid)
        log("bind cid=0x%04X → %s (device reports diverted=%s)".format(cid, action.label, rep.diverted))
        _state.update { s ->
            s.copy(bindings = if (divert) s.bindings + (cid to action) else s.bindings - cid)
        }
        if (divert && action.needsAccessibility && !ActionAccessibilityService.isRunning) {
            log("note: ${action.label} needs the accessibility service — enable it in Settings")
        }
    }

    private fun onNotification(frame: HidppFrame) {
        val idx = reprogFeatureIndex ?: return
        if (frame.deviceIndex != _state.value.settingsDeviceIndex) return
        when (val e = ControlEvents.parse(frame, idx)) {
            is ControlEvent.Buttons -> {
                val t = tracker.update(e.pressed)
                for (cid in t.pressed) {
                    val action = _state.value.bindings[cid]
                    val name = dev.openoptions.hidpp.features.ControlIds.name(cid)
                    if (action == null) {
                        log("button $name pressed (diverted, no action)")
                        _state.update { it.copy(lastButtonEvent = "$name pressed") }
                        continue
                    }
                    val err = ActionRunner.run(getApplication<Application>(), action)
                    val msg = "$name → ${action.label}${if (err != null) " FAILED: $err" else ""}"
                    log("button $msg")
                    _state.update { it.copy(lastButtonEvent = msg) }
                }
                for (cid in t.released) log("button ${dev.openoptions.hidpp.features.ControlIds.name(cid)} released")
            }
            is ControlEvent.RawXy -> log("raw xy dx=${e.dx} dy=${e.dy}")
            null -> {}
        }
    }

    /** Hands every diverted control back to the device. Called before the link is dropped. */
    private suspend fun undivertAll() {
        val d = currentDevice() ?: return
        val bound = _state.value.bindings.keys.toList()
        for (cid in bound) {
            runCatching { ReprogControls.setReporting(d, cid, diverted = false) }
                .onFailure { log("undivert 0x%04X failed: %s".format(cid, it.message)) }
        }
        if (bound.isNotEmpty()) log("undiverted ${bound.size} control(s)")
        _state.update { it.copy(bindings = emptyMap()) }
        tracker.reset()
    }

    fun switchHost(host: Int) = runBusy {
        val d = currentDevice() ?: return@runBusy
        log("switching device to host ${host + 1}; it will disconnect from this phone")
        undivertAll()
        Hosts.switchTo(d, host)
        teardown()
    }

    private fun attach(ch: HidppChannel, label: String) {
        channel = ch
        _state.update { it.copy(connection = label, results = emptyList(), settings = null, settingsDeviceIndex = null) }
        traceJob = viewModelScope.launch {
            ch.trace.collect { (dir, frame) -> log("${if (dir == HidppChannel.Direction.OUT) "→" else "←"} $frame") }
        }
        eventJob = viewModelScope.launch { ch.notifications.collect { onNotification(it) } }
        log("connected: $label")
    }

    /** Undiverts, then drops the link. Safe to call from a busy block; a plain button tap goes through [disconnect]. */
    private suspend fun teardown() {
        if (_state.value.bindings.isNotEmpty()) runCatching { undivertAll() }
        traceJob?.cancel(); traceJob = null
        eventJob?.cancel(); eventJob = null
        reprogFeatureIndex = null
        channel?.let { runCatching { it.close() }; log("disconnected") }
        channel = null
        _state.update { it.copy(connection = null, settings = null, settingsDeviceIndex = null, bindings = emptyMap()) }
    }

    fun disconnect() {
        if (channel == null) return
        viewModelScope.launch { teardown() }
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
        // Best effort: give diverted buttons back before the process goes away.
        runBlocking { withTimeoutOrNull(1_500) { teardown() } }
        runCatching { getApplication<Application>().unregisterReceiver(usbPermissionReceiver) }
    }

    companion object {
        const val ACTION_USB_PERMISSION = "dev.openoptions.USB_PERMISSION"
    }
}
