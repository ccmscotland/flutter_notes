package dev.openoptions.service

import android.annotation.SuppressLint
import android.app.Application
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import dev.openoptions.data.ProfileStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File

/** Process-wide owner of managed devices. Lives as long as the process; the foreground service keeps the process alive. */
@SuppressLint("MissingPermission")
object DeviceManager {
    private lateinit var app: Application
    lateinit var store: ProfileStore
        private set
    val log = LogBuffer()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val managed = HashMap<String, ManagedDevice>()

    private val _states = MutableStateFlow<Map<String, StateFlow<DeviceState>>>(emptyMap())
    /** One state flow per managed device. */
    val states: StateFlow<Map<String, StateFlow<DeviceState>>> = _states

    private val _presence = MutableSharedFlow<String>(extraBufferCapacity = 16)
    val presence: SharedFlow<String> = _presence

    /** Set by the diagnostics screen so managed devices release the link while it probes. */
    @Volatile
    var diagnosticsHold: Boolean = false

    private var initialised = false

    private val aclReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val device = IntentCompat.getParcelableExtra(intent, BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java) ?: return
            when (intent.action) {
                BluetoothDevice.ACTION_ACL_CONNECTED -> { log.add("system: ${device.name ?: device.address} connected"); _presence.tryEmit(device.address) }
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> log.add("system: ${device.name ?: device.address} disconnected")
            }
        }
    }

    @Synchronized
    fun init(application: Application) {
        if (initialised) return
        initialised = true
        app = application
        store = ProfileStore(File(application.filesDir, "profiles.json"))
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        ContextCompat.registerReceiver(application, aclReceiver, filter, ContextCompat.RECEIVER_EXPORTED)
        store.profiles.value.values.filter { it.managed }.forEach { startManaging(it.address) }
    }

    private val bluetooth: BluetoothManager? get() = app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    fun bondedDevices(): List<BluetoothDevice> =
        runCatching { bluetooth?.adapter?.bondedDevices?.toList().orEmpty() }.getOrDefault(emptyList())

    fun connectedAddresses(): Set<String> =
        runCatching { bluetooth?.getConnectedDevices(BluetoothProfile.GATT)?.map { it.address }?.toSet() }.getOrNull().orEmpty()

    fun isSystemConnected(address: String): Boolean = address in connectedAddresses()

    fun device(address: String): ManagedDevice? = managed[address]

    fun setManaged(address: String, name: String?, managedNow: Boolean) {
        store.update(address, name) { it.copy(managed = managedNow) }
        if (managedNow) startManaging(address) else stopManaging(address)
    }

    private fun startManaging(address: String) {
        if (managed.containsKey(address)) return
        val btDevice = bluetooth?.adapter?.getRemoteDevice(address) ?: return
        val md = ManagedDevice(app, btDevice, scope, store, log, presence, ::isSystemConnected) { diagnosticsHold }
        managed[address] = md
        _states.update { it + (address to md.state) }
        md.start()
        DeviceService.ensureRunning(app)
        log.add("managing ${btDevice.name ?: address}")
    }

    private fun stopManaging(address: String) {
        val md = managed.remove(address) ?: return
        _states.update { it - address }
        scope.launch {
            md.stop()
            log.add("stopped managing ${md.state.value.name}")
            if (managed.isEmpty()) DeviceService.stop(app)
        }
    }

    val hasManagedDevices: Boolean get() = managed.isNotEmpty()
}
