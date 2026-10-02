package me.jxl.kiosk_satellite

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.SystemClock
import android.view.KeyEvent

/**
 * Presses a key on the device from Home Assistant, without root or ADB.
 * An app cannot inject arbitrary keys (that needs INJECT_EVENTS, which
 * only the system holds), so each key goes the one way Android leaves open
 * for it:
 *
 *  - media keys: AudioManager.dispatchMediaKeyEvent, to whichever app owns
 *    the active media session - exactly where a remote's play key lands;
 *  - volume: the audio service, with the system volume panel shown;
 *  - back, home, recents, notifications: accessibility global actions;
 *  - the D-pad and OK: accessibility global actions too, but those exist
 *    only from Android 13.
 *
 * Anything else, or a route the device lacks, fails with the reason.
 */
object KeySender {
    val keys = listOf(
        "back", "home", "recents", "notifications",
        "dpad_up", "dpad_down", "dpad_left", "dpad_right", "dpad_center",
        "play_pause", "play", "pause", "stop", "next", "previous",
        "rewind", "fast_forward",
        "volume_up", "volume_down", "volume_mute",
    )

    private val media = mapOf(
        "play_pause" to KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
        "play" to KeyEvent.KEYCODE_MEDIA_PLAY,
        "pause" to KeyEvent.KEYCODE_MEDIA_PAUSE,
        "stop" to KeyEvent.KEYCODE_MEDIA_STOP,
        "next" to KeyEvent.KEYCODE_MEDIA_NEXT,
        "previous" to KeyEvent.KEYCODE_MEDIA_PREVIOUS,
        "rewind" to KeyEvent.KEYCODE_MEDIA_REWIND,
        "fast_forward" to KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
    )

    private val global = mapOf(
        "back" to AccessibilityService.GLOBAL_ACTION_BACK,
        "home" to AccessibilityService.GLOBAL_ACTION_HOME,
        "recents" to AccessibilityService.GLOBAL_ACTION_RECENTS,
        "notifications" to AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS,
    )

    // GLOBAL_ACTION_DPAD_* (API 33), by value so this compiles against
    // any SDK the app targets.
    private val dpad = mapOf(
        "dpad_up" to 16, "dpad_down" to 17, "dpad_left" to 18,
        "dpad_right" to 19, "dpad_center" to 20,
    )

    fun send(context: Context, key: String): Map<String, Any?> {
        media[key]?.let { code ->
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val now = SystemClock.uptimeMillis()
            audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
            audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0))
            return ok()
        }
        when (key) {
            "volume_up", "volume_down", "volume_mute" -> {
                val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val direction = when (key) {
                    "volume_up" -> AudioManager.ADJUST_RAISE
                    "volume_down" -> AudioManager.ADJUST_LOWER
                    else -> AudioManager.ADJUST_TOGGLE_MUTE
                }
                audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI)
                return ok()
            }
        }
        val action = global[key] ?: dpad[key]
            ?: return fail("unknown key '$key'; one of ${keys.joinToString()}")
        if (key in dpad && Build.VERSION.SDK_INT < 33) {
            return fail("$key needs Android 13 or newer; this device runs ${Build.VERSION.RELEASE}")
        }
        val service = KioskAccessibilityService.instance
            ?: return fail("$key needs the Kiosk Satellite accessibility service enabled")
        return if (service.performGlobalAction(action)) ok() else fail("Android refused $key")
    }

    private fun ok() = mapOf("ok" to true)
    private fun fail(error: String) = mapOf("ok" to false, "error" to error)
}
