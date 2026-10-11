package dev.openoptions.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.openoptions.MainActivity
import dev.openoptions.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch

/** Keeps the process alive while devices are managed and shows their state in a persistent notification. */
@OptIn(ExperimentalCoroutinesApi::class)
class DeviceService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var watcher: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        DeviceManager.init(application)
        createChannel()
        startInForeground(buildNotification("Starting…"))
        watcher = scope.launch {
            DeviceManager.states
                .flatMapLatest { map ->
                    if (map.isEmpty()) flowOf(emptyList())
                    else combine(map.values.toList()) { it.toList() }
                }
                .collect { states ->
                    val text = if (states.isEmpty()) "No managed devices" else states.joinToString(" · ") { s ->
                        buildString {
                            append(s.name)
                            when (s.connection) {
                                ConnectionState.CONNECTED -> s.battery?.percent?.let { append(" $it%") }
                                ConnectionState.CONNECTING -> append(" (connecting)")
                                ConnectionState.WAITING -> append(" (away)")
                                ConnectionState.FAILED -> append(" (retrying)")
                                ConnectionState.IDLE -> {}
                            }
                        }
                    }
                    getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(text))
                    delay(500) // coalesce bursts
                }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        watcher?.cancel()
        scope.cancel()
        super.onDestroy()
    }

    private fun startInForeground(n: Notification) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, n, type)
    }

    private fun createChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "Connected devices", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Status of managed Logitech devices"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("OpenOptions")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "devices"
        private const val NOTIFICATION_ID = 1

        fun ensureRunning(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, DeviceService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DeviceService::class.java))
        }
    }
}
