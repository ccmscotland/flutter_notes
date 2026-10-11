package dev.openoptions.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.openoptions.actions.AndroidAction
import dev.openoptions.hidpp.DeviceSettingsSnapshot
import dev.openoptions.hidpp.features.BacklightInfo
import dev.openoptions.hidpp.features.SmartShift

/** Live device settings read over HID++; every control writes straight to the device and re-reads. */
@Composable
fun SettingsSection(
    actions: SettingsActions,
    settings: DeviceSettingsSnapshot,
    enabled: Boolean,
    bindings: Map<Int, AndroidAction> = emptyMap(),
    accessibilityEnabled: Boolean = false,
    lastButtonEvent: String? = null,
) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Device settings", style = MaterialTheme.typography.titleMedium)

            settings.dpi?.let { dpi ->
                Group("Pointer") {
                    val steps = dpi.supported
                    if (steps.size >= 2) {
                        var pos by remember(dpi.current) { mutableFloatStateOf(steps.indexOf(dpi.current).coerceAtLeast(0).toFloat()) }
                        val chosen = steps[pos.toInt().coerceIn(0, steps.lastIndex)]
                        Text("DPI: $chosen (device reports ${dpi.current}, default ${dpi.default})", style = MaterialTheme.typography.bodySmall)
                        Slider(
                            value = pos, onValueChange = { pos = it }, valueRange = 0f..steps.lastIndex.toFloat(),
                            steps = (steps.size - 2).coerceAtLeast(0), enabled = enabled,
                            onValueChangeFinished = { if (chosen != dpi.current) actions.setDpi(chosen) },
                        )
                    } else {
                        Text("DPI ${dpi.current}", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }

            settings.smartShift?.let { ss ->
                Group("Scroll wheel mode") {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(selected = ss.ratchet, onClick = { actions.setRatchet(true) }, label = { Text("Ratchet") }, enabled = enabled)
                        FilterChip(selected = ss.freeSpin, onClick = { actions.setRatchet(false) }, label = { Text("Free spin") }, enabled = enabled)
                    }
                    var t by remember(ss.threshold) { mutableFloatStateOf(ss.threshold.toFloat()) }
                    Text("SmartShift threshold: ${t.toInt()}${if (t.toInt() >= SmartShift.MAX_THRESHOLD) " (never auto-shift)" else ""}", style = MaterialTheme.typography.bodySmall)
                    Slider(
                        value = t, onValueChange = { t = it }, valueRange = SmartShift.MIN_THRESHOLD.toFloat()..SmartShift.MAX_THRESHOLD.toFloat(),
                        enabled = enabled, onValueChangeFinished = { if (t.toInt() != ss.threshold) actions.setSmartShiftThreshold(t.toInt()) },
                    )
                }
            }

            settings.wheel?.let { w ->
                Group("Scroll wheel") {
                    if (w.invertible) ToggleRow("Invert scroll direction", w.inverted, enabled) { actions.setWheelInverted(it) }
                    ToggleRow("High-resolution scrolling", w.highResolution, enabled) { actions.setWheelHighRes(it) }
                    Text("Multiplier ${w.multiplier}${if (w.diverted) " · diverted to app" else ""}", style = MaterialTheme.typography.bodySmall)
                }
            }

            settings.thumbWheel?.let { tw ->
                Group("Thumb wheel") {
                    ToggleRow("Invert thumb wheel", tw.inverted, enabled) { actions.setThumbInverted(it) }
                }
            }

            settings.fnInversion?.let { fn ->
                Group("Function keys") {
                    ToggleRow("F1–F12 as standard function keys", fn.fKeysDefault, enabled) { actions.setFnKeysDefault(it) }
                }
            }

            settings.backlight?.let { b ->
                Group("Backlight") {
                    ToggleRow("Backlight on", b.enabled, enabled) { actions.setBacklightEnabled(it) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (b.supportsAutomatic) FilterChip(selected = b.mode == BacklightInfo.MODE_AUTOMATIC, onClick = { actions.setBacklightMode(BacklightInfo.MODE_AUTOMATIC) }, label = { Text("Automatic") }, enabled = enabled && b.enabled)
                        FilterChip(selected = b.mode == BacklightInfo.MODE_MANUAL, onClick = { actions.setBacklightMode(BacklightInfo.MODE_MANUAL) }, label = { Text("Manual") }, enabled = enabled && b.enabled)
                    }
                    val count = b.levelCount
                    if (count != null && b.mode == BacklightInfo.MODE_MANUAL) {
                        var lvl by remember(b.level) { mutableFloatStateOf(b.level.toFloat()) }
                        Text("Level ${lvl.toInt()} of ${count - 1}", style = MaterialTheme.typography.bodySmall)
                        Slider(
                            value = lvl, onValueChange = { lvl = it }, valueRange = 0f..(count - 1).toFloat(), steps = (count - 2).coerceAtLeast(0),
                            enabled = enabled && b.enabled, onValueChangeFinished = { if (lvl.toInt() != b.level) actions.setBacklightLevel(lvl.toInt()) },
                        )
                    }
                    Text("Timeouts: hands out ${b.durationHandsOutSeconds}s · hands in ${b.durationHandsInSeconds}s · powered ${b.durationPoweredSeconds}s", style = MaterialTheme.typography.bodySmall)
                }
            }

            settings.hosts?.let { h ->
                Group("Easy-Switch hosts") {
                    h.hosts.forEach { slot ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                "${slot.index + 1}. ${slot.name ?: if (slot.paired) "(unnamed)" else "(empty)"}${if (slot.isCurrent) "  ← this device" else ""}",
                                Modifier.weight(1f), style = MaterialTheme.typography.bodySmall,
                            )
                            if (!slot.isCurrent && slot.paired) OutlinedButton(onClick = { actions.switchHost(slot.index) }, enabled = enabled) { Text("Switch") }
                        }
                    }
                }
            }

            if (settings.controls.isNotEmpty()) {
                Group("Buttons and keys (${settings.controls.size})") {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            if (accessibilityEnabled) "Accessibility service: on" else "Accessibility service: off (needed for Back, Home, Recents, …)",
                            Modifier.weight(1f), style = MaterialTheme.typography.bodySmall,
                        )
                        if (!accessibilityEnabled) OutlinedButton(onClick = actions::openAccessibilitySettings) { Text("Enable") }
                    }
                    lastButtonEvent?.let { Text("Last: $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary) }
                    settings.controls.forEach { c ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            val caps = buildList {
                                if (c.reprogrammable) add("remap")
                                if (c.divertable) add("divert")
                                if (c.rawXy) add("gesture")
                                if (c.isFnKey) add("fn")
                            }
                            Text("${c.name}  ·  ${caps.joinToString(", ").ifEmpty { "fixed" }}", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                            if (c.divertable) {
                                ActionPicker(current = bindings[c.cid] ?: AndroidAction.NONE, enabled = enabled) { actions.bind(c.cid, it) }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ActionPicker(current: AndroidAction, enabled: Boolean, onPick: (AndroidAction) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column {
        OutlinedButton(onClick = { open = true }, enabled = enabled) { Text(current.label) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            AndroidAction.entries.forEach { a ->
                DropdownMenuItem(
                    text = { Text(a.label + if (a.needsAccessibility) "  (accessibility)" else "") },
                    onClick = { open = false; if (a != current) onPick(a) },
                )
            }
        }
    }
}

@Composable
private fun Group(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall)
        content()
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}
