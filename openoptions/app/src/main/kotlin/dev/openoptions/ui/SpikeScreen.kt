package dev.openoptions.ui

import android.annotation.SuppressLint
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.openoptions.SpikeState
import dev.openoptions.SpikeViewModel
import dev.openoptions.transport.UsbHidppTransport

@SuppressLint("MissingPermission")
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SpikeScreen(vm: SpikeViewModel, hasBluetoothPermission: Boolean, onRequestBluetooth: () -> Unit, onCopyLog: () -> Unit) {
    val state: SpikeState by vm.state.collectAsStateWithLifecycle()
    LaunchedEffect(hasBluetoothPermission) { if (hasBluetoothPermission) vm.refreshBonded() }

    Scaffold(topBar = { TopAppBar(title = { Text("OpenOptions · Phase 0 spike") }) }) { padding ->
        Column(
            modifier = Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())

            Section("Connection") {
                Text(state.connection ?: "Not connected", style = MaterialTheme.typography.bodyMedium)
                if (state.connection != null) OutlinedButton(onClick = vm::disconnect, enabled = !state.busy) { Text("Disconnect") }
            }

            Section("USB (OTG receiver or wired device)") {
                Button(onClick = vm::refreshUsb, enabled = !state.busy) { Text("Refresh USB devices") }
                if (state.usbDevices.isEmpty()) Text("No Logitech USB devices attached.", style = MaterialTheme.typography.bodySmall)
                state.usbDevices.forEach { d ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(UsbHidppTransport.describe(d), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                        Button(onClick = { vm.requestUsbPermissionAndConnect(d) }, enabled = !state.busy) { Text("Probe") }
                    }
                }
            }

            Section("Bluetooth LE (bonded devices)") {
                if (!hasBluetoothPermission) {
                    Text("Bluetooth permission is needed to list bonded devices.", style = MaterialTheme.typography.bodySmall)
                    Button(onClick = onRequestBluetooth) { Text("Grant Bluetooth permission") }
                } else {
                    Button(onClick = vm::refreshBonded, enabled = !state.busy) { Text("Refresh bonded devices") }
                    if (state.bondedDevices.isEmpty()) Text("No bonded devices. Pair the mouse or keyboard in system Bluetooth settings first.", style = MaterialTheme.typography.bodySmall)
                    else Text("● = connected now. A device paired on several Easy-Switch channels is listed once per channel; only the live one answers.", style = MaterialTheme.typography.bodySmall)
                    state.bondedDevices.forEach { d ->
                        val live = d.address in state.connectedAddresses
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                (if (live) "● " else "○ ") + "${d.name ?: "?"}  ${d.address}",
                                Modifier.weight(1f),
                                style = MaterialTheme.typography.bodySmall,
                                color = if (live) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Button(onClick = { vm.connectBle(d) }, enabled = !state.busy) { Text("Probe") }
                        }
                    }
                }
            }

            Section("Results") {
                if (state.results.isEmpty()) Text("Nothing probed yet.", style = MaterialTheme.typography.bodySmall)
                state.results.sortedBy { it.deviceIndex }.forEach { r ->
                    Text(r.summary(), style = MaterialTheme.typography.bodyMedium)
                }
            }

            state.settings?.let {
                SettingsSection(
                    vm, it, enabled = !state.busy,
                    bindings = state.bindings, accessibilityEnabled = state.accessibilityEnabled, lastButtonEvent = state.lastButtonEvent,
                )
            }

            Section("Log") {
                TextButton(onClick = onCopyLog) { Text("Copy log to clipboard") }
                Column(Modifier.fillMaxWidth().heightIn(max = 400.dp).verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState())) {
                    state.log.takeLast(200).forEach { line ->
                        Text(line, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}
