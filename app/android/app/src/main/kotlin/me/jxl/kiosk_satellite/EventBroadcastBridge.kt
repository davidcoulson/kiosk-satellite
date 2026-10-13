package me.jxl.kiosk_satellite

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Broadcasts that tell other apps on the device what the kiosk is doing
 * (issue #964): Voice Satellite turns and timers, intercom calls, alarms
 * and the screensaver. Dart picks the moments and names the actions
 * (EventBroadcastManager), this only sends them:
 *
 *   me.jxl.kiosk_satellite.event.VS_ENDED
 *
 * Implicit and unrestricted on purpose: Tasker, MacroDroid and
 * tvQuickActions register their receivers in code, which Android 8+ still
 * delivers implicit broadcasts to. FLAG_RECEIVER_FOREGROUND keeps them off
 * the background queue, which can hold a broadcast for seconds, since an
 * app restoring itself after a turn wants it the moment the turn ends.
 */
class EventBroadcastBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "kiosk_satellite/event_broadcasts"
        private const val PREFIX = "me.jxl.kiosk_satellite.event."
    }

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "send") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val name = call.argument<String>("name")
            if (name.isNullOrEmpty()) {
                result.success(false)
                return@setMethodCallHandler
            }
            val intent = Intent(PREFIX + name)
                .addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
            call.argument<Map<String, Any?>>("extras")?.forEach { (key, value) ->
                putExtra(intent, key, value)
            }
            try {
                context.sendBroadcast(intent)
                result.success(true)
            } catch (e: Exception) {
                Log.w("kiosk_satellite", "event broadcast $name failed", e)
                result.success(false)
            }
        }
    }

    /** Each extra as its own type, so Tasker reads a number as a number. */
    private fun putExtra(intent: Intent, key: String, value: Any?) {
        when (value) {
            is String -> intent.putExtra(key, value)
            is Boolean -> intent.putExtra(key, value)
            is Int -> intent.putExtra(key, value)
            is Long -> intent.putExtra(key, value)
            is Double -> intent.putExtra(key, value)
            is List<*> -> intent.putStringArrayListExtra(
                key,
                ArrayList(value.map { "$it" }),
            )
            null -> {}
            else -> intent.putExtra(key, "$value")
        }
    }
}
