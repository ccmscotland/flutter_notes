package dev.openoptions

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.openoptions.service.DeviceManager
import dev.openoptions.ui.DeviceScreen
import dev.openoptions.ui.DeviceViewModel
import dev.openoptions.ui.DevicesScreen
import dev.openoptions.ui.OpenOptionsTheme
import dev.openoptions.ui.SpikeScreen

sealed class Screen {
    data object Devices : Screen()
    data class Device(val address: String) : Screen()
    data object Diagnostics : Screen()
}

class MainActivity : ComponentActivity() {

    private val spikeVm: SpikeViewModel by viewModels()
    private var hasBluetoothPermission by mutableStateOf(false)
    private var screen by mutableStateOf<Screen>(Screen.Devices)

    private val requestBluetooth = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        hasBluetoothPermission = granted
        spikeVm.log("bluetooth permission ${if (granted) "granted" else "denied"}")
    }

    private val requestNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DeviceManager.init(application)
        hasBluetoothPermission = checkBluetoothPermission()
        if (!hasBluetoothPermission) requestBluetoothPermission()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        handleUsbIntent(intent)
        setContent {
            OpenOptionsTheme {
                when (val s = screen) {
                    Screen.Devices -> DevicesScreen(
                        hasBluetoothPermission = hasBluetoothPermission,
                        onRequestBluetooth = ::requestBluetoothPermission,
                        onOpenDevice = { screen = Screen.Device(it) },
                        onOpenDiagnostics = { screen = Screen.Diagnostics },
                    )
                    is Screen.Device -> {
                        BackHandler { screen = Screen.Devices }
                        val vm: DeviceViewModel = viewModel(key = s.address, factory = deviceVmFactory(s.address))
                        DeviceScreen(vm = vm, onBack = { screen = Screen.Devices }, onCopyLog = { copy(vm.logText()) })
                    }
                    Screen.Diagnostics -> {
                        BackHandler { screen = Screen.Devices }
                        SpikeScreen(
                            vm = spikeVm,
                            hasBluetoothPermission = hasBluetoothPermission,
                            onRequestBluetooth = ::requestBluetoothPermission,
                            onCopyLog = { copy(spikeVm.logText()) },
                            onBack = { screen = Screen.Devices },
                        )
                    }
                }
            }
        }
    }

    private fun deviceVmFactory(address: String) = object : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = DeviceViewModel(application, address) as T
    }

    override fun onResume() {
        super.onResume()
        spikeVm.refreshAccessibilityStatus()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleUsbIntent(intent)
    }

    private fun handleUsbIntent(intent: Intent?) {
        if (intent?.action == UsbManager.ACTION_USB_DEVICE_ATTACHED) {
            spikeVm.log("usb attached intent received")
            spikeVm.refreshUsb()
            screen = Screen.Diagnostics
        }
    }

    private fun checkBluetoothPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    private fun requestBluetoothPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) requestBluetooth.launch(Manifest.permission.BLUETOOTH_CONNECT)
        else hasBluetoothPermission = true
    }

    private fun copy(text: String) {
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("openoptions-log", text))
        Toast.makeText(this, "Log copied", Toast.LENGTH_SHORT).show()
    }
}
