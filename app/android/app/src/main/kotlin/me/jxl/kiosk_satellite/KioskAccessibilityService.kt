package me.jxl.kiosk_satellite

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/**
 * The System UI guard: an accessibility service that closes the two system
 * surfaces the kiosk cannot otherwise reach, the moment they open.
 *
 * Everything else the kiosk defends is an app-level surface: back is
 * swallowed in dispatchKeyEvent, touches die on the shield, a lost
 * foreground is reclaimed. The notification shade and the recents screen
 * are SystemUI's own windows — an app can watch them appear but cannot
 * touch them, and the pre-12 tricks for slamming the shade shut
 * (StatusBarManager.collapsePanels reflection, ACTION_CLOSE_SYSTEM_DIALOGS)
 * are blocked on modern Android. What Android offers instead, to
 * accessibility services only, is [GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE]
 * (API 31). This is the same route the commercial kiosk vendors take, and
 * unlike screen pinning it shows nobody a consent dialog: the owner enables
 * the service once in Android's Accessibility settings and it stays.
 *
 * The service reads no window content ([canRetrieveWindowContent] is off in
 * its XML config) and reacts only to window-state changes: SystemUI showing
 * a window while the shade guard is armed, or a recents surface appearing
 * while the recents guard is.
 *
 * Arming rides the same flag push as every other kiosk protection
 * (KioskLock forwards it from the Dart bundle into the statics below — the
 * service runs in the app's process, so statics are enough). At boot the
 * system binds this service before any Activity exists; [onServiceConnected]
 * seeds from the settings mirror so a kiosk that starts on boot is guarded
 * from the first frame.
 *
 * The same service carries remote key mappings ([RemoteKeys]): with a
 * remote_key gesture configured it asks Android for key events
 * ([filterKeys]) and swallows the mapped keys before the focused app sees
 * them. Only then - a device with no remote keys routes no key through it.
 */
class KioskAccessibilityService : AccessibilityService() {
    companion object {
        /// Close the notification shade / quick settings whenever they open.
        @Volatile
        var guardShade = false

        /// Back straight out of the recents screen whenever it opens.
        @Volatile
        var guardRecents = false

        /// Bound and live. The system binds enabled accessibility services
        /// for as long as the process runs, so this doubles as "the owner
        /// has enabled the guard in Accessibility settings".
        @Volatile
        var running = false
            private set

        /// The app whose Activity was last brought to the front, from the
        /// window-state events this service receives anyway: the
        /// foreground app without Usage access. Null until one is seen.
        @Volatile
        var foregroundPackage: String? = null
            private set

        /// The bound service, for switching key filtering on and off as
        /// remote key mappings come and go. Main thread only.
        @Volatile
        var instance: KioskAccessibilityService? = null
            private set
    }

    /// Whether Android is sending this service key events right now.
    var filteringKeys = false
        private set

    /**
     * Ask for key events, or stop. The XML declares only the capability
     * (canRequestFilterKeyEvents); the flag is set here at runtime, so key
     * filtering exists exactly while a remote key mapping or a capture
     * needs it.
     */
    fun filterKeys(on: Boolean) {
        val info = serviceInfo ?: return
        val flag = AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
        if ((info.flags and flag != 0) != on) {
            info.flags = if (on) info.flags or flag else info.flags and flag.inv()
            serviceInfo = info
        }
        filteringKeys = on
    }

    override fun onKeyEvent(event: KeyEvent): Boolean = RemoteKeys.onKey(event)

    override fun onServiceConnected() {
        super.onServiceConnected()
        running = true
        instance = this
        RemoteKeys.serviceConnected(this)
        if (!guardShade && !guardRecents) {
            val prefs =
                getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val lockdown =
                prefs.getBoolean("flutter.ks.lockdown.enabled", false)
            val kioskShade =
                prefs.getBoolean("flutter.ks.kiosk.enabled", false) &&
                    prefs.getBoolean(
                        "flutter.ks.kiosk.disable_status_bar", false)
            guardShade = lockdown || kioskShade
            guardRecents = lockdown
        }
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        released()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        released()
        super.onDestroy()
    }

    private fun released() {
        running = false
        if (instance === this) instance = null
        filteringKeys = false
        RemoteKeys.serviceGone(applicationContext)
    }

    private val main = Handler(Looper.getMainLooper())
    private var burst: Runnable? = null
    private var burstUntil = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            return
        }
        val pkg = event.packageName?.toString() ?: return
        val cls = event.className?.toString() ?: ""
        noteForeground(pkg, cls)
        // Any SystemUI window while armed: the dismiss is a no-op unless
        // the shade or quick settings are actually open, so firing it on
        // a volume panel or a transient bar costs nothing.
        if (guardShade && pkg == "com.android.systemui") dismissBurst()
        // Recents is quickstep's RecentsActivity on stock, Samsung and most
        // OEM launchers alike. Back returns to the task below it: us.
        if (guardRecents && cls.contains("RecentsActivity")) {
            performGlobalAction(GLOBAL_ACTION_BACK)
        }
    }

    /** Window classes already judged: an Activity (true) or not (a
     *  dialog, a toast, the IME). */
    private val activityClasses = HashMap<String, Boolean>()

    /** A window-state change counts as the foreground app only when the
     *  window is an Activity: a volume panel or a keyboard comes and goes
     *  over the app without replacing it. */
    private fun noteForeground(pkg: String, cls: String) {
        if (cls.isEmpty()) return
        val key = "$pkg/$cls"
        val isActivity = activityClasses.getOrPut(key) {
            try {
                packageManager.getActivityInfo(android.content.ComponentName(pkg, cls), 0)
                true
            } catch (_: Exception) {
                false
            }
        }
        if (isActivity) foregroundPackage = pkg
    }

    /**
     * One dismiss per event is not enough: the event fires when the shade
     * window appears, but the system will not collapse a panel mid-drag,
     * so a single dismiss is spent before the finger lifts and the shade
     * then sits open until some later event. Repeating the dismiss every
     * ~120 ms for a couple of seconds lands the collapse the moment the
     * system accepts one; every extra shot is a no-op on a closed shade.
     */
    private fun dismissBurst() {
        burstUntil = SystemClock.uptimeMillis() + 2000
        if (burst != null) return
        val shot = object : Runnable {
            override fun run() {
                if (!guardShade || SystemClock.uptimeMillis() > burstUntil) {
                    burst = null
                    return
                }
                if (Build.VERSION.SDK_INT >= 31) {
                    performGlobalAction(GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
                } else {
                    // Best effort below 31: back collapses an open shade.
                    performGlobalAction(GLOBAL_ACTION_BACK)
                }
                main.postDelayed(this, 120)
            }
        }
        burst = shot
        shot.run()
    }

    override fun onInterrupt() {}
}
