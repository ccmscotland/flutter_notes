package dev.openoptions.ui

import android.annotation.SuppressLint
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.openoptions.service.ConnectionState
import dev.openoptions.service.DeviceManager
import dev.openoptions.service.DeviceState

private val logitechHints = listOf("MX ", "MX", "Logi", "K380", "K480", "K580", "M5", "M7", "Pebble", "Lift", "POP", "Signature", "ERGO", "Keys", "Anywhere", "Master", "Pro X", "G ")

@SuppressLint("MissingPermission")
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(hasBluetoothPermission: Boolean, onRequestBluetooth: () -> Unit, onOpenDevice: (String) -> Unit, onOpenDiagnostics: () -> Unit) {
    val statesMap by DeviceManager.states.collectAsStateWithLifecycle()
    val profiles by DeviceManager.store.profiles.collectAsStateWithLifecycle()
    var refreshKey by remember { mutableStateOf(0) }
    val bonded = remember(refreshKey, hasBluetoothPermission) { if (hasBluetoothPermission) DeviceManager.bondedDevices() else emptyList() }
    val connected = remember(refreshKey, hasBluetoothPermission) { if (hasBluetoothPermission) DeviceManager.connectedAddresses() else emptySet() }

    val rows = bonded.map { d ->
        val name = d.name ?: profiles[d.address]?.name ?: d.address
        val likely = logitechHints.any { name.startsWith(it, ignoreCase = true) } || profiles.containsKey(d.address)
        Triple(d.address, name, likely)
    }.sortedWith(compareBy({ !(profiles[it.first]?.managed ?: false) }, { it.first !in connected }, { !it.third }, { it.second }))

    Scaffold(topBar = {
        TopAppBar(title = { Text("OpenOptions") }, actions = {
            TextButton(onClick = { refreshKey++ }) { Text("Refresh") }
            TextButton(onClick = onOpenDiagnostics) { Text("Diagnostics") }
        })
    }) { padding ->
        if (!hasBluetoothPermission) {
            Column(Modifier.padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Bluetooth permission is needed to see paired devices.")
                TextButton(onClick = onRequestBluetooth) { Text("Grant permission") }
            }
            return@Scaffold
        }
        LazyColumn(Modifier.padding(padding).fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item {
                Text(
                    "Turn on Manage for a Logitech device to keep it configured and its button actions working in the background. Devices paired on several Easy-Switch channels appear once per channel; manage the one marked connected.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            items(rows, key = { it.first }) { (address, name, likely) ->
                val managed = profiles[address]?.managed ?: false
                val stateFlow = statesMap[address]
                val state: DeviceState? = if (stateFlow != null) stateFlow.collectAsStateWithLifecycle().value else null
                Card(Modifier.fillMaxWidth().clickable { onOpenDevice(address) }) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(name, style = MaterialTheme.typography.titleMedium, color = if (likely) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
                            val status = when {
                                state == null -> if (address in connected) "connected to phone" else "not connected"
                                state.connection == ConnectionState.CONNECTED -> buildString {
                                    append("managed · connected")
                                    state.battery?.percent?.let { append(" · $it%") }
                                }
                                else -> "managed · ${state.detail ?: state.connection.name.lowercase()}"
                            }
                            Text(status, style = MaterialTheme.typography.bodySmall)
                            Text(address, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("Manage", style = MaterialTheme.typography.labelSmall)
                            Switch(checked = managed, onCheckedChange = { DeviceManager.setManaged(address, name, it) })
                        }
                    }
                }
            }
        }
    }
}
