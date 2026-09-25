package me.jxl.kiosk_satellite

import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Exists only so Android lets Kiosk Satellite see other apps' media
 * sessions: MediaSessionManager.getActiveSessions answers an app whose
 * notification listener is enabled, and nobody else. It reads no
 * notifications - every callback is left at the platform's no-op - and it
 * is enabled by the owner (Settings, Notification access) or, with
 * WRITE_SECURE_SETTINGS granted, by [AccessibilityKeeper] while
 * agent.now_playing is on.
 */
class KioskNotificationListener : NotificationListenerService() {
    override fun onListenerConnected() {
        super.onListenerConnected()
        MediaSessions.refresh(applicationContext)
    }
}

/**
 * What is playing on the device, whatever app plays it: Plezy, Kodi,
 * YouTube. Follows the active media sessions, picks the one playing (else
 * the most recent), and reports its app, title, artist and state to Dart,
 * which publishes them to Home Assistant. Controls go back through the
 * session's transport controls, the way a Bluetooth remote's play key
 * would.
 */
object MediaSessions {
    private const val TAG = "MediaSessions"
    private val main = Handler(Looper.getMainLooper())

    private var channel: MethodChannel? = null
    private var manager: MediaSessionManager? = null
    private var watching = false
    private var current: MediaController? = null
    private var lastSent: Map<String, Any?>? = null

    fun listener(context: Context) = ComponentName(context, KioskNotificationListener::class.java)

    /** Whether the owner (or the keeper) has enabled the listener. */
    fun hasAccess(context: Context): Boolean {
        val enabled = Settings.Secure.getString(
            context.contentResolver, "enabled_notification_listeners") ?: return false
        val me = listener(context)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    fun attach(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        val ch = MethodChannel(messenger, "kiosk_satellite/media_sessions")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(
                    mapOf("access" to hasAccess(app)) + (lastSent ?: emptyMap()),
                )
                "control" -> result.success(control(call.argument<String>("action") ?: ""))
                "refresh" -> {
                    refresh(app)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        refresh(app)
    }

    private val sessionsChanged = MediaSessionManager.OnActiveSessionsChangedListener { list ->
        pick(list ?: emptyList())
    }

    private val callback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = report()
        override fun onMetadataChanged(metadata: MediaMetadata?) = report()
        override fun onSessionDestroyed() {
            current = null
            refreshSoon()
        }
    }

    private var appContext: Context? = null

    private fun refreshSoon() {
        val ctx = appContext ?: return
        main.post { refresh(ctx) }
    }

    /** Start (or restart) watching; a no-op without notification access. */
    fun refresh(context: Context) {
        appContext = context.applicationContext
        if (!hasAccess(context)) {
            report()
            return
        }
        try {
            val msm = manager ?: (context.getSystemService(Context.MEDIA_SESSION_SERVICE)
                as MediaSessionManager).also { manager = it }
            if (!watching) {
                msm.addOnActiveSessionsChangedListener(sessionsChanged, listener(context), main)
                watching = true
            }
            pick(msm.getActiveSessions(listener(context)))
        } catch (e: SecurityException) {
            // The listener was disabled under us.
            watching = false
            Log.w(TAG, "no media session access: ${e.message}")
            report()
        }
    }

    /** The session that matters: one that is playing, else the newest. */
    private fun pick(sessions: List<MediaController>) {
        val chosen = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: sessions.firstOrNull()
        if (chosen?.sessionToken != current?.sessionToken) {
            current?.unregisterCallback(callback)
            current = chosen
            chosen?.registerCallback(callback, main)
        }
        report()
    }

    private fun stateName(state: Int?): String = when (state) {
        PlaybackState.STATE_PLAYING -> "playing"
        PlaybackState.STATE_PAUSED -> "paused"
        PlaybackState.STATE_BUFFERING, PlaybackState.STATE_CONNECTING -> "buffering"
        PlaybackState.STATE_STOPPED -> "stopped"
        PlaybackState.STATE_ERROR -> "error"
        null, PlaybackState.STATE_NONE -> "idle"
        else -> "idle"
    }

    private fun report() {
        val ctx = appContext
        val c = current
        val meta = c?.metadata
        val pkg = c?.packageName ?: ""
        val label = if (pkg.isEmpty() || ctx == null) "" else try {
            val pm = ctx.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Exception) {
            pkg
        }
        val snapshot = mapOf(
            "access" to (ctx?.let { hasAccess(it) } ?: false),
            "state" to if (c == null) "idle" else stateName(c.playbackState?.state),
            "package" to pkg,
            "app" to label,
            "title" to (meta?.getString(MediaMetadata.METADATA_KEY_TITLE)
                ?: meta?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE) ?: ""),
            "artist" to (meta?.getString(MediaMetadata.METADATA_KEY_ARTIST)
                ?: meta?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""),
            "album" to (meta?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""),
            "durationMs" to (meta?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L),
        )
        if (snapshot == lastSent) return
        lastSent = snapshot
        channel?.invokeMethod("changed", snapshot)
    }

    /** play, pause, play_pause, next, previous, stop. */
    fun control(action: String): Map<String, Any?> {
        val c = current ?: return mapOf("ok" to false, "error" to "nothing is playing")
        val t = c.transportControls
        when (action) {
            "play" -> t.play()
            "pause" -> t.pause()
            "play_pause" ->
                if (c.playbackState?.state == PlaybackState.STATE_PLAYING) t.pause() else t.play()
            "next" -> t.skipToNext()
            "previous" -> t.skipToPrevious()
            "stop" -> t.stop()
            else -> return mapOf("ok" to false, "error" to "unknown action $action")
        }
        return mapOf("ok" to true)
    }
}
