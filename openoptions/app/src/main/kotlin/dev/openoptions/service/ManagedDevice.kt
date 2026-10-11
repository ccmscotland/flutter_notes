package dev.openoptions.service

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.Context
import dev.openoptions.actions.ActionRunner
import dev.openoptions.actions.AndroidAction
import dev.openoptions.data.DeviceProfile
import dev.openoptions.data.ProfileStore
import dev.openoptions.hidpp.DeviceProbe
import dev.openoptions.hidpp.DeviceSettings
import dev.openoptions.hidpp.DeviceSettingsSnapshot
import dev.openoptions.hidpp.Features
import dev.openoptions.hidpp.Hidpp20Device
import dev.openoptions.hidpp.HidppChannel
import dev.openoptions.hidpp.HidppFrame
import dev.openoptions.hidpp.ProbeResult
import dev.openoptions.hidpp.features.BatteryEvents
import dev.openoptions.hidpp.features.BatteryInfo
import dev.openoptions.hidpp.features.ControlEvent
import dev.openoptions.hidpp.features.ControlEvents
import dev.openoptions.hidpp.features.ControlIds
import dev.openoptions.hidpp.features.DivertedButtonTracker
import dev.openoptions.hidpp.features.ReprogControls
import dev.openoptions.transport.BleHidppTransport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

enum class ConnectionState { IDLE, WAITING, CONNECTING, CONNECTED, FAILED }

data class DeviceState(
    val address: String,
    val name: String,
    val connection: ConnectionState = ConnectionState.IDLE,
    val detail: String? = null,
    val probe: ProbeResult? = null,
    val settings: DeviceSettingsSnapshot? = null,
    val battery: BatteryInfo? = null,
    val lastEvent: String? = null,
)

/**
 * Owns one device for as long as it is managed: connects when the system reports it present, applies the saved
 * profile, serves settings changes, runs diverted-button actions, and reconnects after a drop.
 */
@SuppressLint("MissingPermission")
class ManagedDevice(
    private val context: Context,
    private val device: BluetoothDevice,
    private val scope: CoroutineScope,
    private val store: ProfileStore,
    private val log: LogBuffer,
    private val presence: SharedFlow<String>,
    private val isSystemConnected: (String) -> Boolean,
    private val isHeld: () -> Boolean,
) {
    val address: String = device.address

    private val _state = MutableStateFlow(DeviceState(address, device.name ?: store.get(address)?.name ?: address))
    val state: StateFlow<DeviceState> = _state

    private var job: Job? = null
    private var transport: BleHidppTransport? = null
    private var channel: HidppChannel? = null
    private var hid: Hidpp20Device? = null
    private var reprogIndex: Int? = null
    private var unifiedBatteryIndex: Int? = null
    private var legacyBatteryIndex: Int? = null
    private val tracker = DivertedButtonTracker()
    private val opMutex = Mutex()
    private var divertedCids: Set<Int> = emptySet()

    private fun profile(): DeviceProfile = store.get(address) ?: DeviceProfile(address, _state.value.name)

    fun start() {
        if (job?.isActive == true) return
        job = scope.launch { loop() }
    }

    suspend fun stop() {
        job?.cancel(); job = null
        teardown("stopped")
        _state.update { it.copy(connection = ConnectionState.IDLE, detail = null) }
    }

    private suspend fun loop() {
        var failures = 0
        while (scope.isActive) {
            if (isHeld()) { _state.update { it.copy(connection = ConnectionState.WAITING, detail = "diagnostics in use") }; delay(2_000); continue }
            if (!isSystemConnected(address)) {
                _state.update { it.copy(connection = ConnectionState.WAITING, detail = "waiting for device") }
                withTimeoutOrNull(60_000) { presence.first { it == address } }
                continue
            }
            try {
                connectAndServe()
                failures = 0
            } catch (e: Exception) {
                failures++
                val wait = minOf(60_000L, 3_000L * (1 shl minOf(failures, 4)))
                log.add("$address: ${e.message ?: e}; retry in ${wait / 1000}s")
                _state.update { it.copy(connection = ConnectionState.FAILED, detail = e.message) }
                teardown(null)
                delay(wait)
            }
        }
    }

    private suspend fun connectAndServe() {
        _state.update { it.copy(connection = ConnectionState.CONNECTING, detail = null) }
        val t = BleHidppTransport(context, device, log::add)
        transport = t
        t.connect()
        t.framing = BleHidppTransport.Framing.PAYLOAD_ONLY
        val ch = HidppChannel(t, scope, timeoutMs = 4_000)
        channel = ch
        val events = scope.launch { ch.notifications.collect { onNotification(it) } }
        try {
            val probe = DeviceProbe.probe(ch, HidppChannel.DIRECT_DEVICE_INDEX)
            val d = Hidpp20Device(ch, HidppChannel.DIRECT_DEVICE_INDEX)
            hid = d
            reprogIndex = d.featureIndex(Features.REPROG_CONTROLS_V4)
            unifiedBatteryIndex = d.featureIndex(Features.UNIFIED_BATTERY)
            legacyBatteryIndex = d.featureIndex(Features.BATTERY_STATUS)
            val name = probe.name ?: _state.value.name
            store.update(address, name = name) { it }
            _state.update { it.copy(name = name, probe = probe, battery = probe.battery) }
            log.add("$name connected: ${probe.summary()}")

            val p = profile()
            if (!p.overrides.isEmpty) {
                val n = p.overrides.applyTo(d) { section, e -> log.add("$name: could not apply $section: ${e.message}") }
                log.add("$name: applied $n saved setting(s)")
            }
            for ((cid, action) in p.bindings) {
                if (action == AndroidAction.NONE) continue
                runCatching { ReprogControls.setReporting(d, cid, diverted = true) }
                    .onSuccess { divertedCids = divertedCids + cid }
                    .onFailure { log.add("$name: could not divert ${ControlIds.name(cid)}: ${it.message}") }
            }
            if (divertedCids.isNotEmpty()) log.add("$name: diverted ${divertedCids.map { ControlIds.name(it) }}")

            refreshSettings(d)
            _state.update { it.copy(connection = ConnectionState.CONNECTED, detail = null) }
            t.closed.await()
            log.add("$name: link dropped")
        } finally {
            events.cancel()
            teardown(null)
            _state.update { it.copy(connection = ConnectionState.WAITING, detail = "reconnecting") }
        }
    }

    private suspend fun refreshSettings(d: Hidpp20Device) {
        val snap = DeviceSettings.read(d) { section, e -> log.add("${_state.value.name}: $section: ${e.message}") }
        _state.update { it.copy(settings = snap) }
    }

    private fun onNotification(frame: HidppFrame) {
        BatteryEvents.parse(frame, unifiedBatteryIndex, legacyBatteryIndex)?.let { b ->
            _state.update { it.copy(battery = b) }
            log.add("${_state.value.name}: battery $b")
            return
        }
        val idx = reprogIndex ?: return
        when (val e = ControlEvents.parse(frame, idx)) {
            is ControlEvent.Buttons -> {
                val t = tracker.update(e.pressed)
                for (cid in t.pressed) {
                    val action = profile().bindings[cid] ?: continue
                    val err = ActionRunner.run(context, action)
                    val msg = "${ControlIds.name(cid)} → ${action.label}${if (err != null) " failed: $err" else ""}"
                    log.add("${_state.value.name}: $msg")
                    _state.update { it.copy(lastEvent = msg) }
                }
            }
            is ControlEvent.RawXy -> {}
            null -> {}
        }
    }

    /** Runs [block] against the connected device, then re-reads settings. Returns false when not connected. */
    suspend fun withDevice(label: String, block: suspend (Hidpp20Device) -> Unit): Boolean = opMutex.withLock {
        val d = hid ?: return false
        try {
            block(d)
            log.add("${_state.value.name}: $label")
            refreshSettings(d)
            true
        } catch (e: Exception) {
            log.add("${_state.value.name}: $label failed: ${e.message}")
            false
        }
    }

    /** Diverts or restores [cid] on the live device to match [action]. */
    suspend fun applyBinding(cid: Int, action: AndroidAction): Boolean = opMutex.withLock {
        val d = hid ?: return false
        val divert = action != AndroidAction.NONE
        runCatching { ReprogControls.setReporting(d, cid, diverted = divert) }
            .onSuccess { divertedCids = if (divert) divertedCids + cid else divertedCids - cid; log.add("${_state.value.name}: ${ControlIds.name(cid)} → ${action.label}") }
            .onFailure { log.add("${_state.value.name}: bind failed: ${it.message}") }
            .isSuccess
    }

    private suspend fun teardown(reason: String?) {
        val d = hid
        if (d != null && divertedCids.isNotEmpty() && transport?.closed?.isCompleted == false) {
            for (cid in divertedCids) runCatching { withTimeoutOrNull(1_500) { ReprogControls.setReporting(d, cid, diverted = false) } }
            log.add("${_state.value.name}: undiverted ${divertedCids.size} control(s)")
        }
        divertedCids = emptySet()
        tracker.reset()
        hid = null
        reprogIndex = null
        channel?.let { runCatching { it.close() } }
        channel = null
        transport = null
        if (reason != null) log.add("${_state.value.name}: $reason")
    }
}
