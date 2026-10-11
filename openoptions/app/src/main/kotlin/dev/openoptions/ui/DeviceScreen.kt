package dev.openoptions.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.openoptions.service.ConnectionState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceScreen(vm: DeviceViewModel, onBack: () -> Unit, onCopyLog: () -> Unit) {
    val state by vm.state.collectAsStateWithLifecycle()
    val profile by vm.profile.collectAsStateWithLifecycle()
    val busy by vm.busy.collectAsStateWithLifecycle()
    val accessibility by vm.accessibilityEnabled.collectAsStateWithLifecycle()
    val log by vm.log.collectAsStateWithLifecycle()
    var showLog by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { vm.refreshAccessibilityStatus() }

    val title = state?.name?.takeIf { it.isNotBlank() } ?: profile.name.ifBlank { vm.address }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(title) },
            navigationIcon = { TextButton(onClick = onBack) { Text("Back") } },
            actions = { TextButton(onClick = { showLog = !showLog }) { Text(if (showLog) "Hide log" else "Log") } },
        )
    }) { padding ->
        Column(
            Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())

            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            val s = state
                            val line = when {
                                s == null -> "Not managed. Turn on Manage to connect and keep this device configured."
                                s.connection == ConnectionState.CONNECTED -> "Connected"
                                else -> "${s.connection.name.lowercase().replaceFirstChar { it.uppercase() }}${s.detail?.let { " · $it" } ?: ""}"
                            }
                            Text(line, style = MaterialTheme.typography.bodyMedium)
                            s?.battery?.let { Text("Battery $it", style = MaterialTheme.typography.bodySmall) }
                            s?.probe?.let { p ->
                                Text(
                                    listOfNotNull(p.type?.label, "HID++ ${p.protocol}", p.firmware.firstOrNull { it.kind == 0 }?.toString()).joinToString(" · "),
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                        }
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("Manage", style = MaterialTheme.typography.labelSmall)
                            Switch(checked = profile.managed, onCheckedChange = { vm.setManaged(it) })
                        }
                    }
                    if (!profile.overrides.isEmpty || profile.bindings.isNotEmpty()) {
                        Text(
                            "Saved: ${listOfNotNull(
                                if (!profile.overrides.isEmpty) "settings" else null,
                                if (profile.bindings.isNotEmpty()) "${profile.bindings.size} button action(s)" else null,
                            ).joinToString(", ")} — reapplied on every connection.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }

            val settings = state?.settings
            if (settings != null) {
                SettingsSection(
                    actions = vm, settings = settings, enabled = !busy && state?.connection == ConnectionState.CONNECTED,
                    bindings = profile.bindings, accessibilityEnabled = accessibility, lastButtonEvent = state?.lastEvent,
                )
            } else if (state != null) {
                Text("Settings appear once the device is connected.", style = MaterialTheme.typography.bodySmall)
            }

            if (showLog) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        TextButton(onClick = onCopyLog) { Text("Copy log to clipboard") }
                        Column(Modifier.fillMaxWidth().heightIn(max = 400.dp).verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState())) {
                            log.takeLast(200).forEach { Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall) }
                        }
                    }
                }
            }
        }
    }
}
