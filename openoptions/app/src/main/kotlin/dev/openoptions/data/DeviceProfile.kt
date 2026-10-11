package dev.openoptions.data

import dev.openoptions.actions.AndroidAction
import dev.openoptions.hidpp.SettingsOverrides
import org.json.JSONObject

/** Everything the app remembers about one device, keyed by its Bluetooth address. */
data class DeviceProfile(
    val address: String,
    val name: String,
    val managed: Boolean = false,
    val overrides: SettingsOverrides = SettingsOverrides(),
    val bindings: Map<Int, AndroidAction> = emptyMap(),
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("address", address)
        put("name", name)
        put("managed", managed)
        put("overrides", JSONObject().apply {
            overrides.dpi?.let { put("dpi", it) }
            overrides.ratchet?.let { put("ratchet", it) }
            overrides.smartShiftThreshold?.let { put("smartShiftThreshold", it) }
            overrides.wheelInverted?.let { put("wheelInverted", it) }
            overrides.wheelHighRes?.let { put("wheelHighRes", it) }
            overrides.thumbInverted?.let { put("thumbInverted", it) }
            overrides.fKeysDefault?.let { put("fKeysDefault", it) }
            overrides.backlightEnabled?.let { put("backlightEnabled", it) }
            overrides.backlightMode?.let { put("backlightMode", it) }
            overrides.backlightLevel?.let { put("backlightLevel", it) }
        })
        put("bindings", JSONObject().apply { bindings.forEach { (cid, a) -> put(cid.toString(), a.name) } })
    }

    companion object {
        fun fromJson(o: JSONObject): DeviceProfile {
            val ov = o.optJSONObject("overrides") ?: JSONObject()
            fun int(k: String): Int? = if (ov.has(k)) ov.getInt(k) else null
            fun bool(k: String): Boolean? = if (ov.has(k)) ov.getBoolean(k) else null
            val b = o.optJSONObject("bindings") ?: JSONObject()
            val bindings = HashMap<Int, AndroidAction>()
            for (k in b.keys()) {
                val action = runCatching { AndroidAction.valueOf(b.getString(k)) }.getOrNull() ?: continue
                k.toIntOrNull()?.let { bindings[it] = action }
            }
            return DeviceProfile(
                address = o.getString("address"),
                name = o.optString("name", ""),
                managed = o.optBoolean("managed", false),
                overrides = SettingsOverrides(
                    dpi = int("dpi"), ratchet = bool("ratchet"), smartShiftThreshold = int("smartShiftThreshold"),
                    wheelInverted = bool("wheelInverted"), wheelHighRes = bool("wheelHighRes"), thumbInverted = bool("thumbInverted"),
                    fKeysDefault = bool("fKeysDefault"), backlightEnabled = bool("backlightEnabled"), backlightMode = int("backlightMode"),
                    backlightLevel = int("backlightLevel"),
                ),
                bindings = bindings,
            )
        }
    }
}
