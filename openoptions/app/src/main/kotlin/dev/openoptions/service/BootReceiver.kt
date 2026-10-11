package dev.openoptions.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.openoptions.data.ProfileStore
import java.io.File

/** Restarts device management after a reboot when any device is managed. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val anyManaged = ProfileStore(File(context.filesDir, "profiles.json")).profiles.value.values.any { it.managed }
        if (anyManaged) DeviceService.ensureRunning(context)
    }
}
