package me.jxl.kiosk_satellite

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.ViewConfiguration
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

/**
 * Remote key mappings: a hardware key on the device's remote runs a gesture
 * action, whatever app is in front.
 *
 * Nothing an app can do sees keys while another app is focused - on a
 * projector the focus is the TV input showing HDMI, and it keeps Home and
 * the gear key for itself. An accessibility service that asks to filter
 * key events gets every hardware key before the focused app does, and may
 * swallow it: that is [KioskAccessibilityService.onKeyEvent], which hands
 * each key to [onKey] here.
 *
 * The mappings are the `remote_key` entries of gestures.mappings, pushed
 * from Dart ([RemoteKeysBridge]) and seeded from the settings mirror at
 * process start, so a key works from boot before Dart has run. A key is
 * matched on its Android key code only, never the scan code, so one mapping
 * covers every remote that sends that key.
 *
 * Launching an app, a deep link or Android settings runs right here, with
 * no Dart involved: those are the actions a remote most wants, and they
 * then work the instant the service binds, on an agent with no gestures
 * page, and with the Flutter engine still starting. Every other action is
 * handed to Dart, which runs it like any other gesture.
 *
 * Not every key can be mapped. A vendor window policy that keeps a key's
 * press for itself (interceptKeyBeforeQueueing) takes it before any filter
 * runs, and Android then withholds the release too, since a service is
 * never shown a release without its press: the NexiGo Aurora's MediaTek
 * build did this to the gear key (F4), until [GearKeyActivity] gave its
 * firmware somewhere to send the key. Capture reports such a key as no key
 * at all.
 *
 * Keys are compared against the table and never logged, stored or read as
 * text. The service asks Android for key events only while there is a
 * mapping to match or a capture waiting ([wantsKeys]), so a device with no
 * remote keys routes nothing through it.
 */
object RemoteKeys {
    private const val TAG = "RemoteKeys"
    private const val PREFS = "FlutterSharedPreferences"
    private const val MAPPINGS_KEY = "flutter.ks.gestures.mappings"
    private const val ENABLED_KEY = "flutter.ks.gestures.remote_keys.enabled"

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var enabled = true

    @Volatile
    private var configured = false

    @Volatile
    private var bridge: RemoteKeysBridge? = null

    /** Capture: the next key pressed is reported rather than acted on. */
    private var captureUntil = 0L


    /** The key a capture took: its release (and repeats) are ours too. */
    private var captured: Int? = null

    private val matcher = RemoteKeyMatcher(
        longPressMs = ViewConfiguration.getLongPressTimeout().toLong().coerceAtLeast(400),
        schedule = { delay, run -> main.postDelayed(run, delay) },
        cancel = { run -> main.removeCallbacks(run) },
        fire = { fire(it) },
    )

    /** The context the native actions start from: the service, once bound. */
    @Volatile
    private var context: Context? = null

    fun attach(bridge: RemoteKeysBridge, context: Context) {
        this.bridge = bridge
        if (this.context == null) this.context = context.applicationContext
        if (!configured) seed(context)
    }

    /** The service bound: activities start from its context from now on. */
    fun serviceConnected(service: KioskAccessibilityService) {
        context = service
        if (!configured) seed(service)
        applyFilter()
    }

    fun serviceGone(appContext: Context) {
        context = appContext.applicationContext
    }

    /** Before Dart has pushed anything: read the settings mirror, so a
     *  projector's Home key works from boot. */
    private fun seed(context: Context) {
        try {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            enabled = prefs.getBoolean(ENABLED_KEY, true)
            matcher.mappings = parseRemoteKeyMappings(prefs.getString(MAPPINGS_KEY, null))
        } catch (e: Exception) {
            Log.w(TAG, "could not read the remote key mappings: $e")
        }
    }

    /** Dart's push: the whole gestures.mappings JSON and the switch. */
    fun configure(mappingsJson: String?, enabled: Boolean) {
        configured = true
        this.enabled = enabled
        matcher.mappings = parseRemoteKeyMappings(mappingsJson)
        applyFilter()
    }

    val mappingCount: Int get() = matcher.mappings.size

    /** Report the next key rather than acting on it, for up to [seconds]. */
    fun capture(seconds: Int) {
        captureUntil = SystemClock.uptimeMillis() + seconds.coerceIn(1, 120) * 1000L
        applyFilter()
        main.removeCallbacks(captureExpired)
        main.postDelayed(captureExpired, seconds.coerceIn(1, 120) * 1000L + 50)
    }

    fun cancelCapture() {
        captureUntil = 0L
        main.removeCallbacks(captureExpired)
        applyFilter()
    }

    private val captureExpired = Runnable { applyFilter() }

    private val capturing: Boolean get() = SystemClock.uptimeMillis() < captureUntil

    /** Whether the service should be filtering keys at all. A captured
     *  key keeps it on until its release arrives: switched off after the
     *  down, the up went to the app instead and left the key looking held. */
    fun wantsKeys(): Boolean =
        capturing || captured != null || (enabled && matcher.mappings.isNotEmpty())

    private fun applyFilter() {
        main.post { KioskAccessibilityService.instance?.filterKeys(wantsKeys()) }
    }

    /** One key event from the service. True consumes it. */
    fun onKey(event: KeyEvent): Boolean {
        val code = event.keyCode
        if (captured == code) {
            val freshDown = event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0
            if (!freshDown) {
                if (event.action == KeyEvent.ACTION_UP) {
                    captured = null
                    applyFilter()
                }
                return true
            }
            // A new press of the captured key: its release never came, so
            // the capture is over and this press is judged on its own.
            captured = null
        }
        if (capturing && event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            captureUntil = 0L
            captured = code
            main.removeCallbacks(captureExpired)
            bridge?.captured(code, keyName(code))
            return true
        }
        if (!enabled) return false
        return when (event.action) {
            KeyEvent.ACTION_DOWN -> matcher.onDown(code, event.repeatCount)
            KeyEvent.ACTION_UP -> matcher.onUp(code)
            else -> false
        }
    }

    private fun fire(mapping: RemoteKeyMapping) {
        val ctx = context
        val ran: Boolean? = if (ctx == null) null else when (mapping.actionType) {
            "launch_app" -> AppLaunch.launchApp(ctx, mapping.target)
            "open_uri" -> AppLaunch.openUri(ctx, mapping.target)
            "android_settings" -> AppLaunch.openSystemSettings(ctx)
            else -> null
        }
        // Dart logs every press, and runs the ones that were not native.
        bridge?.pressed(mapping.id, ran)
    }

    /** "KEYCODE_MEDIA_PLAY_PAUSE" as "Media Play Pause", the way the
     *  editors name a key. */
    fun keyName(code: Int): String =
        KeyEvent.keyCodeToString(code)
            .removePrefix("KEYCODE_")
            .split('_')
            .filter { it.isNotEmpty() }
            .joinToString(" ") { part ->
                if (part.length <= 2 && part.any(Char::isDigit)) part
                else part.lowercase().replaceFirstChar(Char::uppercase)
            }
}

/** One remote_key mapping, reduced to what the service needs. */
data class RemoteKeyMapping(
    val id: String,
    val keyCode: Int,
    val longPress: Boolean,
    val actionType: String,
    /** The package for launch_app, the URI for open_uri. */
    val target: String?,
)

/** The remote_key entries of a gestures.mappings JSON array. Anything
 *  malformed is skipped, as the Dart decoder does. */
fun parseRemoteKeyMappings(json: String?): List<RemoteKeyMapping> {
    if (json.isNullOrBlank()) return emptyList()
    val out = mutableListOf<RemoteKeyMapping>()
    try {
        val list = JSONArray(json)
        for (i in 0 until list.length()) {
            val entry = list.optJSONObject(i) ?: continue
            val id = entry.optString("id")
            val trigger = entry.optJSONObject("trigger") ?: continue
            val action = entry.optJSONObject("action") ?: continue
            if (id.isEmpty() || trigger.optString("type") != "remote_key") continue
            val code = trigger.optInt("keyCode", -1)
            if (code <= 0) continue
            val type = action.optString("type")
            out.add(
                RemoteKeyMapping(
                    id = id,
                    keyCode = code,
                    longPress = trigger.optBoolean("longPress", false),
                    actionType = type,
                    target = when (type) {
                        "launch_app" -> action.optString("package").ifEmpty { null }
                        "open_uri" -> action.optString("uri").ifEmpty { null }
                        else -> null
                    },
                ),
            )
        }
    } catch (_: Exception) {
        // Unparseable JSON reads as no mappings.
    }
    return out
}

/**
 * One press at a time: which key the service owns, and whether it became a
 * long press. Free of Android types so it tests on the JVM.
 *
 * A key with only a short mapping fires on the way down: nothing to wait
 * for. A key with a long mapping waits: the long action fires when the key
 * is still held at [longPressMs], and the short one (if any) on release
 * before that. Android marks long presses with FLAG_LONG_PRESS on a key
 * repeat, but repeats are synthesized after the accessibility filter, and a
 * key the filter swallowed has none, so the service times the press itself.
 *
 * A key with only a long mapping is still owned for its short presses:
 * whether a press will turn long is unknowable on the way down, and a
 * swallowed down cannot be given back. The editors say so.
 */
class RemoteKeyMatcher(
    private val longPressMs: Long,
    private val schedule: (Long, Runnable) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val fire: (RemoteKeyMapping) -> Unit,
) {
    @Volatile
    var mappings: List<RemoteKeyMapping> = emptyList()

    private var held: Int? = null
    private var pendingShort: RemoteKeyMapping? = null
    private var longTimer: Runnable? = null

    /** True consumes the down (and its repeats). */
    fun onDown(keyCode: Int, repeatCount: Int): Boolean {
        // Repeats of the owned press. A fresh down of the same key is a new
        // press, even if the last one's release never arrived.
        if (held == keyCode && repeatCount > 0) return true
        // The rest of a press that began before a mapping existed, or
        // before this key was owned: not ours to take halfway.
        if (repeatCount > 0) return false
        val table = mappings
        val short = table.firstOrNull { it.keyCode == keyCode && !it.longPress }
        val long = table.firstOrNull { it.keyCode == keyCode && it.longPress }
        if (short == null && long == null) return false
        drop()
        held = keyCode
        if (long == null) {
            fire(short!!)
            return true
        }
        pendingShort = short
        val timer = Runnable {
            if (held == keyCode) {
                longTimer = null
                pendingShort = null
                fire(long)
            }
        }
        longTimer = timer
        schedule(longPressMs, timer)
        return true
    }

    /** True consumes the up. */
    fun onUp(keyCode: Int): Boolean {
        if (held != keyCode) return false
        val short = pendingShort
        val beforeLong = longTimer != null
        drop()
        if (beforeLong && short != null) fire(short)
        return true
    }

    private fun drop() {
        longTimer?.let(cancel)
        longTimer = null
        pendingShort = null
        held = null
    }
}

/**
 * Dart's handle on the key table, on the engine-scoped messenger: it has to
 * work on an agent, which never opens an Activity, and headless after boot.
 */
class RemoteKeysBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "kiosk_satellite/remote_keys")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "configure" -> {
                    RemoteKeys.configure(
                        call.argument<String>("mappings"),
                        call.argument<Boolean>("enabled") ?: true,
                    )
                    result.success(null)
                }
                "capture" -> {
                    RemoteKeys.capture(call.argument<Int>("seconds") ?: 20)
                    result.success(KioskAccessibilityService.running)
                }
                "cancelCapture" -> {
                    RemoteKeys.cancelCapture()
                    result.success(null)
                }
                "status" -> result.success(
                    mapOf(
                        "serviceRunning" to KioskAccessibilityService.running,
                        "filtering" to (KioskAccessibilityService.instance?.filteringKeys ?: false),
                        "mappings" to RemoteKeys.mappingCount,
                        "canKeepEnabled" to AccessibilityKeeper.canKeep(context),
                    ),
                )
                else -> result.notImplemented()
            }
        }
        RemoteKeys.attach(this, context)
    }

    /** A mapped key fired. [ran] is the native action's outcome, or null
     *  when Dart must run the action itself. */
    fun pressed(id: String, ran: Boolean?) {
        channel.invokeMethod("pressed", mapOf("id" to id, "ran" to ran))
    }

    fun captured(keyCode: Int, name: String) {
        channel.invokeMethod("captured", mapOf("keyCode" to keyCode, "name" to name))
    }
}
