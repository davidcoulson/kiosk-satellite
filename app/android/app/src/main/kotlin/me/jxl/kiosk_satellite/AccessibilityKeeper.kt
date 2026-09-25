package me.jxl.kiosk_satellite

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log

/**
 * Keeps Kiosk Satellite's accessibility service enabled.
 *
 * The service carries remote key mappings and the System UI guard, and some
 * firmware turns it off behind the owner's back: the HY260 projector's
 * system clears enabled_accessibility_services and accessibility_enabled
 * at random, and a reboot there comes up with them empty. Whatever the
 * trigger, the fix is the same one kiosk apps use: watch the two settings
 * and put the service back.
 *
 * Writing a secure setting needs android.permission.WRITE_SECURE_SETTINGS,
 * which only adb can grant:
 *
 *   adb shell pm grant me.jxl.kiosk_satellite android.permission.WRITE_SECURE_SETTINGS
 *
 * Without the grant this does nothing. With it, the grant is the owner's
 * opt-in, and device.keep_accessibility (default on) is the way back out.
 * The service is appended to whatever else is enabled (Projectivy's,
 * a screen reader), never written over it.
 */
object AccessibilityKeeper {
    private const val TAG = "AccessibilityKeeper"
    private const val PREFS = "FlutterSharedPreferences"
    private const val KEEP_KEY = "flutter.ks.device.keep_accessibility"
    private const val NOW_PLAYING_KEY = "flutter.ks.device.now_playing"
    private const val LISTENERS = "enabled_notification_listeners"

    // Set when the keeper itself enabled the notification listener, so
    // turning Now playing off takes back only what the keeper gave.
    private const val LISTENER_ADDED_KEY = "ks_internal.keeper.listener_added"

    private val main = Handler(Looper.getMainLooper())

    // The self-repair record, kept in the settings mirror's file under
    // keys Dart never reads as settings, so it survives restarts and the
    // repairs made at boot, before Dart is listening, still count.
    private const val COUNT_KEY = "ks_internal.self_repairs.count"
    private const val LAST_KEY = "ks_internal.self_repairs.last"
    private const val WHAT_KEY = "ks_internal.self_repairs.what"

    /** Told of each repair as it happens; set by RemoteKeysBridge. */
    @Volatile
    var onRepaired: ((Map<String, Any?>) -> Unit)? = null

    /** {count, last (epoch ms, 0 = never), what}. */
    fun record(context: Context): Map<String, Any?> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return mapOf(
            "count" to prefs.getInt(COUNT_KEY, 0),
            "last" to prefs.getLong(LAST_KEY, 0L),
            "what" to (prefs.getString(WHAT_KEY, "") ?: ""),
        )
    }

    private fun noteRepair(context: Context, what: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit()
            .putInt(COUNT_KEY, prefs.getInt(COUNT_KEY, 0) + 1)
            .putLong(LAST_KEY, System.currentTimeMillis())
            .putString(WHAT_KEY, what)
            .apply()
        val record = record(context)
        main.post { onRepaired?.invoke(record) }
    }
    private var observer: ContentObserver? = null

    // Held strongly: SharedPreferences keeps its listeners weakly.
    private var prefsListener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    fun install(context: Context) {
        val app = context.applicationContext
        if (observer != null) return
        val watch = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                ensure(app)
            }
        }
        observer = watch
        val resolver = app.contentResolver
        resolver.registerContentObserver(
            Settings.Secure.getUriFor(Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES), false, watch)
        resolver.registerContentObserver(
            Settings.Secure.getUriFor(Settings.Secure.ACCESSIBILITY_ENABLED), false, watch)
        resolver.registerContentObserver(Settings.Secure.getUriFor(LISTENERS), false, watch)
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == KEEP_KEY || key == NOW_PLAYING_KEY) ensure(app)
        }
        prefsListener = listener
        prefs.registerOnSharedPreferenceChangeListener(listener)
        ensure(app)
        // A grant made while the app runs changes neither setting, so no
        // change notice would say it is time to act; a minute's poll does.
        // It costs a permission check and a settings read.
        main.postDelayed(object : Runnable {
            override fun run() {
                ensure(app)
                main.postDelayed(this, POLL_MS)
            }
        }, POLL_MS)
    }

    private const val POLL_MS = 60_000L

    /** Whether the grant is there, for the status the editors show. */
    fun canKeep(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED

    /** Put the service back if it is missing. Safe to call any time: it
     *  writes only what is missing, so its own write's change notice finds
     *  nothing left to do. */
    fun ensure(context: Context) {
        try {
            ensureListener(context)
        } catch (e: Exception) {
            Log.w(TAG, "could not update notification access: $e")
        }
        try {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(KEEP_KEY, true) || !canKeep(context)) return
            val resolver = context.contentResolver
            val me = ComponentName(context, KioskAccessibilityService::class.java)
            val current = Settings.Secure.getString(
                resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            val merged = withService(current, me)
            if (merged != null) {
                Settings.Secure.putString(
                    resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, merged)
                Log.i(TAG, "accessibility service was turned off; turned it back on")
                noteRepair(context, "Accessibility service turned back on")
            }
            if (Settings.Secure.getInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0) != 1) {
                Settings.Secure.putInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            }
        } catch (e: Exception) {
            Log.w(TAG, "could not restore the accessibility service: $e")
        }
    }

    /**
     * Notification access for Now playing (MediaSessions): granted while
     * device.now_playing is on, and taken back when it goes off - but
     * only if the keeper was the one that granted it.
     */
    private fun ensureListener(context: Context) {
        if (!canKeep(context)) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val resolver = context.contentResolver
        val me = MediaSessions.listener(context)
        val current = Settings.Secure.getString(resolver, LISTENERS)
        if (prefs.getBoolean(NOW_PLAYING_KEY, false)) {
            val merged = withService(current, me) ?: return
            Settings.Secure.putString(resolver, LISTENERS, merged)
            prefs.edit().putBoolean(LISTENER_ADDED_KEY, true).apply()
            if (prefs.getBoolean(LISTENER_ADDED_KEY + ".once", false)) {
                noteRepair(context, "Notification access turned back on")
            }
            prefs.edit().putBoolean(LISTENER_ADDED_KEY + ".once", true).apply()
            MediaSessions.refresh(context)
        } else if (prefs.getBoolean(LISTENER_ADDED_KEY, false)) {
            val kept = withoutService(current, me)
            if (kept != null) Settings.Secure.putString(resolver, LISTENERS, kept)
            prefs.edit().putBoolean(LISTENER_ADDED_KEY, false)
                .putBoolean(LISTENER_ADDED_KEY + ".once", false).apply()
            MediaSessions.refresh(context)
        }
    }

    /** [current] without [service], or null when it was not there. */
    fun withoutService(current: String?, service: ComponentName): String? {
        val entries = (current ?: "").split(':').map { it.trim() }
            .filter { it.isNotEmpty() && it != "null" }
        val kept = entries.filter { ComponentName.unflattenFromString(it) != service }
        return if (kept.size == entries.size) null else kept.joinToString(":")
    }

    /** [current] with [service] appended, or null when it is already there.
     *  An unset list reads back as null or "null"; empty entries are
     *  dropped rather than kept as a leading colon. */
    fun withService(current: String?, service: ComponentName): String? {
        val entries = (current ?: "").split(':')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != "null" }
        if (entries.any { ComponentName.unflattenFromString(it) == service }) return null
        return (entries + service.flattenToString()).joinToString(":")
    }
}
