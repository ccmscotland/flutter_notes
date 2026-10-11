package dev.openoptions.ui

import android.app.Application
import android.content.Intent
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.openoptions.actions.ActionAccessibilityService
import dev.openoptions.actions.AndroidAction
import dev.openoptions.data.DeviceProfile
import dev.openoptions.hidpp.SettingsOverrides
import dev.openoptions.hidpp.features.AdjustableDpi
import dev.openoptions.hidpp.features.Backlight
import dev.openoptions.hidpp.features.FnInversion
import dev.openoptions.hidpp.features.HiResWheel
import dev.openoptions.hidpp.features.Hosts
import dev.openoptions.hidpp.features.SmartShift
import dev.openoptions.hidpp.features.ThumbWheel
import dev.openoptions.service.DeviceManager
import dev.openoptions.service.DeviceState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** Bridges one device's screen to [DeviceManager] and the profile store. Changes persist, then go to the device if connected. */
@OptIn(ExperimentalCoroutinesApi::class)
class DeviceViewModel(app: Application, val address: String) : AndroidViewModel(app), SettingsActions {

    private val manager = DeviceManager

    val state: StateFlow<DeviceState?> = manager.states
        .flatMapLatest { map -> map[address] ?: MutableStateFlow<DeviceState?>(null) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val profile: StateFlow<DeviceProfile> = manager.store.profiles
        .map { it[address] ?: DeviceProfile(address, "") }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), manager.store.get(address) ?: DeviceProfile(address, ""))

    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy

    private val _accessibility = MutableStateFlow(ActionAccessibilityService.isRunning)
    val accessibilityEnabled: StateFlow<Boolean> = _accessibility

    fun refreshAccessibilityStatus() { _accessibility.value = ActionAccessibilityService.isRunning }

    val log: StateFlow<List<String>> = manager.log.lines

    fun setManaged(managed: Boolean) = manager.setManaged(address, profile.value.name.ifBlank { null }, managed)

    private fun change(label: String, patch: (SettingsOverrides) -> SettingsOverrides, write: suspend (dev.openoptions.hidpp.Hidpp20Device) -> Unit) {
        manager.store.update(address) { it.copy(overrides = patch(it.overrides)) }
        viewModelScope.launch {
            _busy.value = true
            try {
                val sent = manager.device(address)?.withDevice(label, write) ?: false
                if (!sent) manager.log.add("$label saved; will apply when the device connects")
            } finally { _busy.value = false }
        }
    }

    override fun setDpi(dpi: Int) = change("dpi=$dpi", { it.copy(dpi = dpi) }) { AdjustableDpi.set(it, dpi) }
    override fun setRatchet(ratchet: Boolean) = change("ratchet=$ratchet", { it.copy(ratchet = ratchet) }) { SmartShift.set(it, ratchet = ratchet) }
    override fun setSmartShiftThreshold(t: Int) = change("threshold=$t", { it.copy(smartShiftThreshold = t) }) { SmartShift.set(it, threshold = t) }
    override fun setWheelInverted(v: Boolean) = change("wheelInverted=$v", { it.copy(wheelInverted = v) }) { HiResWheel.set(it, inverted = v) }
    override fun setWheelHighRes(v: Boolean) = change("wheelHighRes=$v", { it.copy(wheelHighRes = v) }) { HiResWheel.set(it, highResolution = v) }
    override fun setThumbInverted(v: Boolean) = change("thumbInverted=$v", { it.copy(thumbInverted = v) }) { ThumbWheel.set(it, inverted = v) }
    override fun setFnKeysDefault(v: Boolean) = change("fKeysDefault=$v", { it.copy(fKeysDefault = v) }) { FnInversion.set(it, v) }
    override fun setBacklightEnabled(v: Boolean) = change("backlightEnabled=$v", { it.copy(backlightEnabled = v) }) { Backlight.write(it, enabled = v) }
    override fun setBacklightMode(mode: Int) = change("backlightMode=$mode", { it.copy(backlightMode = mode) }) { Backlight.write(it, mode = mode) }
    override fun setBacklightLevel(level: Int) = change("backlightLevel=$level", { it.copy(backlightLevel = level) }) { Backlight.write(it, level = level) }

    override fun switchHost(host: Int) {
        viewModelScope.launch {
            manager.device(address)?.withDevice("switch to host ${host + 1}") { Hosts.switchTo(it, host) }
        }
    }

    override fun bind(cid: Int, action: AndroidAction) {
        manager.store.update(address) { p ->
            p.copy(bindings = if (action == AndroidAction.NONE) p.bindings - cid else p.bindings + (cid to action))
        }
        viewModelScope.launch {
            val ok = manager.device(address)?.applyBinding(cid, action) ?: false
            if (!ok) manager.log.add("binding saved; will apply when the device connects")
        }
    }

    override fun openAccessibilitySettings() {
        runCatching {
            getApplication<Application>().startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    fun logText(): String = manager.log.text()
}
