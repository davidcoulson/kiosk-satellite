package me.jxl.kiosk_satellite

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Agent mode, as the native side sees it: read straight from the
 * shared_preferences store, since most of the callers run with no Dart
 * engine up yet (a boot, a package replace, a restart alarm).
 *
 * An agent has no dashboard, and its screen belongs to whatever the box is
 * for. Starting the Activity there takes that screen away - on a NexiGo
 * projector the TV input pauses and the vendor service switches the laser
 * on in an empty room - so every relaunch path asks here first and brings
 * back only the keep-alive service, which is all an agent runs behind:
 * ESPHome, the remote admin, updates and plugins. The Activity still opens
 * when someone opens it (the launcher icon, the notification).
 */
object AgentMode {
    fun isOn(context: Context): Boolean =
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.ks.device.agent_mode", false)

    /** Brings the process back with no Activity: the service start is what
     *  creates the process, and the Application starts the engine. */
    fun startHeadless(context: Context) = KioskSatelliteService.ensureRunning(context)
}

/** The agent's restart alarm lands here (see BackgroundBridge.restartProcess). */
class AgentRestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AgentMode.startHeadless(context)
    }
}
