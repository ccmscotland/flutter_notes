package dev.openoptions.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File

/** JSON-file-backed store of [DeviceProfile]s. Small enough to write synchronously. */
class ProfileStore(private val file: File) {

    private val lock = Any()
    private val _profiles = MutableStateFlow(load())
    val profiles: StateFlow<Map<String, DeviceProfile>> = _profiles

    fun get(address: String): DeviceProfile? = _profiles.value[address]

    /** Creates the profile if needed, applies [transform], persists, and returns the new value. */
    fun update(address: String, name: String? = null, transform: (DeviceProfile) -> DeviceProfile): DeviceProfile {
        synchronized(lock) {
            val current = _profiles.value[address] ?: DeviceProfile(address, name ?: "")
            val renamed = if (name != null && name.isNotBlank() && name != current.name) current.copy(name = name) else current
            val next = transform(renamed)
            _profiles.value = _profiles.value + (address to next)
            save(_profiles.value)
            return next
        }
    }

    private fun load(): Map<String, DeviceProfile> {
        if (!file.exists()) return emptyMap()
        return runCatching {
            val root = JSONObject(file.readText())
            val devices = root.optJSONObject("devices") ?: JSONObject()
            val out = HashMap<String, DeviceProfile>()
            for (k in devices.keys()) {
                runCatching { DeviceProfile.fromJson(devices.getJSONObject(k)) }.getOrNull()?.let { out[it.address] = it }
            }
            out
        }.getOrElse { emptyMap() }
    }

    private fun save(map: Map<String, DeviceProfile>) {
        val root = JSONObject().put("version", 1).put("devices", JSONObject().apply { map.values.forEach { put(it.address, it.toJson()) } })
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(root.toString())
        if (!tmp.renameTo(file)) { file.writeText(root.toString()); tmp.delete() }
    }
}
