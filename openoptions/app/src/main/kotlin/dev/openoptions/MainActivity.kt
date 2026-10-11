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
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import dev.openoptions.ui.OpenOptionsTheme
import dev.openoptions.ui.SpikeScreen

class MainActivity : ComponentActivity() {

    private val vm: SpikeViewModel by viewModels()
    private var hasBluetoothPermission by mutableStateOf(false)

    private val requestBluetooth = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        hasBluetoothPermission = granted
        vm.log("bluetooth permission ${if (granted) "granted" else "denied"}")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hasBluetoothPermission = checkBluetoothPermission()
        handleUsbIntent(intent)
        setContent {
            OpenOptionsTheme {
                SpikeScreen(
                    vm = vm,
                    hasBluetoothPermission = hasBluetoothPermission,
                    onRequestBluetooth = ::requestBluetoothPermission,
                    onCopyLog = ::copyLog,
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleUsbIntent(intent)
    }

    private fun handleUsbIntent(intent: Intent?) {
        if (intent?.action == UsbManager.ACTION_USB_DEVICE_ATTACHED) {
            vm.log("usb attached intent received")
            vm.refreshUsb()
        }
    }

    private fun checkBluetoothPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    private fun requestBluetoothPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) requestBluetooth.launch(Manifest.permission.BLUETOOTH_CONNECT)
        else hasBluetoothPermission = true
    }

    private fun copyLog() {
        val cm = getSystemService(ClipboardManager::class.java)
        cm.setPrimaryClip(ClipData.newPlainText("openoptions-log", vm.logText()))
        Toast.makeText(this, "Log copied", Toast.LENGTH_SHORT).show()
    }
}
