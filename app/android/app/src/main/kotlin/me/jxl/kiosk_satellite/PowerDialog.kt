package me.jxl.kiosk_satellite

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Answering a vendor's power-off dialog.
 *
 * On a projector the remote's power key does not go to Android's own
 * power menu but to the vendor's: the HY260 opens com.htc.closedialog
 * (persist.sys.power_class names its WeiMiMainActivity), with Shutdown
 * focused and a fifteen second countdown that shuts the box down when
 * nobody picks anything else. A shutdown ends Kiosk Satellite until
 * someone powers the box on again, so the family's power-button press
 * should put the projector to sleep instead. Nothing an app can do
 * reaches another app's dialog - except an accessibility service, which
 * [KioskAccessibilityService] already is for remote keys.
 *
 * device.power_dialog_package names the dialog's package and
 * device.power_dialog_choice the answer:
 *
 *  - [SLEEP] (the default) closes the dialog with Back (Home if Back
 *    did not take) and then performs the service's lock-screen action,
 *    which is PowerManager.goToSleep under the hood - what a Sleep row
 *    does on the firmwares that show one. The HY260's layout carries an
 *    rl_sleep row that is never made visible, so this is the only way
 *    to sleep it.
 *  - [DISMISS] only closes the dialog: the power key then does nothing.
 *  - Anything else is the view id of a button to press, the full id
 *    being package:id/choice (rl_reboot on the HY260). With window
 *    content access the service sees the dialog's views and clicks one.
 *
 * A dialog that appears within [PowerDialogAnswerer.wakeGraceMs] of the
 * screen coming on is the wake-up press itself on a firmware that shows
 * the dialog then; it is only dismissed, so a sleeping box never falls
 * straight back asleep when someone wakes it.
 *
 * The settings are pushed from Dart ([RemoteKeysBridge]) and seeded from
 * the settings mirror when the service binds, so the dialog is answered
 * from boot before Dart has run. The service watches window-state
 * changes anyway; while a view id is the answer it also asks for
 * window-content changes ([KioskAccessibilityService.watchContent]),
 * since a dialog's buttons are not always inflated by the time its
 * window is announced. Each appearance is answered once: after an
 * answer, events from the dialog are ignored for a few seconds, so the
 * changes the answer itself causes do not answer it again. A dialog
 * whose button never turns up is logged, once, after the retries have
 * had their chance.
 */
object PowerDialog {
    private const val TAG = "PowerDialog"
    private const val PREFS = "FlutterSharedPreferences"
    private const val PACKAGE_KEY = "flutter.ks.device.power_dialog_package"
    private const val CHOICE_KEY = "flutter.ks.device.power_dialog_choice"
    const val SLEEP = "sleep"
    const val DISMISS = "dismiss"
    const val DEFAULT_CHOICE = SLEEP

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var configured = false

    @Volatile
    private var bridge: RemoteKeysBridge? = null

    private var watchingScreen = false

    private val answerer = PowerDialogAnswerer(
        now = { SystemClock.uptimeMillis() },
        schedule = { delay, run -> main.postDelayed(run, delay) },
        cancel = { run -> main.removeCallbacks(run) },
        report = { choice, found, detail -> report(choice, found, detail) },
        actions = ServiceActions,
    )

    fun attach(bridge: RemoteKeysBridge) {
        this.bridge = bridge
    }

    /** The service bound: read the mirror if Dart has not spoken yet,
     *  ask for content events if a view id wants them, and start
     *  noticing the screen waking. */
    fun serviceConnected(service: KioskAccessibilityService) {
        if (!configured) seed(service)
        service.watchContent(answerer.wantsContent())
        if (!watchingScreen) {
            watchingScreen = true
            // The application context outlives any one binding of the
            // service; the firmware that clears and restores the service
            // rebinds it often.
            service.applicationContext.registerReceiver(
                object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        answerer.screenOn()
                    }
                },
                IntentFilter(Intent.ACTION_SCREEN_ON),
            )
        }
    }

    private fun seed(context: Context) {
        try {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            answerer.packageName = prefs.getString(PACKAGE_KEY, null) ?: ""
            answerer.choice = prefs.getString(CHOICE_KEY, null)?.trim()?.ifEmpty { null }
                ?: DEFAULT_CHOICE
        } catch (e: Exception) {
            Log.w(TAG, "could not read the power dialog settings: $e")
        }
    }

    /** Dart's push: the dialog's package (empty = off) and the answer. */
    fun configure(packageName: String?, choice: String?) {
        configured = true
        answerer.packageName = packageName?.trim() ?: ""
        answerer.choice = choice?.trim()?.ifEmpty { null } ?: DEFAULT_CHOICE
        main.post { KioskAccessibilityService.instance?.watchContent(answerer.wantsContent()) }
    }

    val packageName: String get() = answerer.packageName

    /** One window event from the service. Cheap unless it is the dialog's. */
    fun onEvent(service: KioskAccessibilityService, event: AccessibilityEvent) {
        val pkg = event.packageName?.toString() ?: return
        if (!answerer.concerns(pkg)) return
        val appeared = event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        answerer.onWindow(pkg, appeared) { dialogRoot(service, event, pkg) }
    }

    /**
     * The dialog's view tree: the event's own source walked up to its
     * root, else the active window (a dialog Activity takes focus), else
     * whichever window on screen belongs to the package.
     */
    private fun dialogRoot(
        service: KioskAccessibilityService,
        event: AccessibilityEvent,
        pkg: String,
    ): DialogNode? {
        val roots = sequence {
            runCatching { event.source }.getOrNull()?.let { source ->
                var node: AccessibilityNodeInfo = source
                while (true) node = node.parent ?: break
                yield(node)
            }
            service.rootInActiveWindow?.let { yield(it) }
            runCatching { service.windows }.getOrNull()?.forEach { window ->
                window.root?.let { yield(it) }
            }
        }
        val root = roots.firstOrNull { it.packageName?.toString() == pkg } ?: return null
        return NodeInfoNode(root)
    }

    private fun report(choice: String, found: Boolean, detail: String) {
        val suffix = if (detail.isEmpty()) "" else " ($detail)"
        when {
            found -> Log.i(TAG, "answered the power dialog with $choice$suffix")
            choice == SLEEP || choice == DISMISS ->
                Log.w(TAG, "could not answer the power dialog with $choice$suffix")
            else -> Log.w(TAG, "power dialog shown but $choice not found$suffix")
        }
        bridge?.powerDialog(choice, found, detail)
    }

    /** The global actions on whichever instance of the service is bound
     *  when the answer is due. */
    private object ServiceActions : GlobalActions {
        private val service get() = KioskAccessibilityService.instance

        override fun back(): Boolean =
            service?.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK) ?: false

        override fun home(): Boolean =
            service?.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME) ?: false

        /** GLOBAL_ACTION_LOCK_SCREEN is Android 9's; below it there is no
         *  sleep an app may ask for without being a device admin. */
        override fun lockScreen(): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
            return service?.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN)
                ?: false
        }

        override fun dialogShowing(pkg: String): Boolean {
            val s = service ?: return false
            if (s.rootInActiveWindow?.packageName?.toString() == pkg) return true
            return runCatching { s.windows }.getOrNull()
                ?.any { it.root?.packageName?.toString() == pkg } ?: false
        }
    }
}

/** What the service can do to the screen as a whole. Free of Android
 *  types so the logic tests on the JVM. */
interface GlobalActions {
    fun back(): Boolean
    fun home(): Boolean
    fun lockScreen(): Boolean

    /** Whether a window of [pkg] is still on screen. */
    fun dialogShowing(pkg: String): Boolean
}

/** A view in a dialog, as much of AccessibilityNodeInfo as answering one
 *  needs. Free of Android types so the logic tests on the JVM. */
interface DialogNode {
    val isClickable: Boolean
    val parent: DialogNode?

    /** Every view under this one carrying the full resource id. */
    fun findByViewId(id: String): List<DialogNode>
    fun click(): Boolean
    fun focus(): Boolean
}

/**
 * Press the view [viewId] under [root]: the view itself when it is
 * clickable, else its nearest clickable ancestor (a button's label is
 * often the node carrying the id, inside the clickable row), and failing
 * both, the view focused and clicked - the default-focused button is what
 * some dialogs answer on. True when a click landed.
 */
fun answerDialog(root: DialogNode, viewId: String): Boolean {
    val target = root.findByViewId(viewId).firstOrNull() ?: return false
    var node: DialogNode? = target
    while (node != null) {
        if (node.isClickable && node.click()) return true
        node = node.parent
    }
    return target.focus() && target.click()
}

/**
 * When to answer and when to stay quiet. One appearance of the dialog is
 * answered once: [answeredForMs] after an answer, further events from the
 * dialog are ignored.
 *
 * A view-id answer: a window-state change that finds no button is not
 * yet a miss - the buttons may still be inflating, and the content
 * changes that follow retry - so the miss is reported only when nothing
 * has landed [missAfterMs] later.
 *
 * A [PowerDialog.SLEEP] or [PowerDialog.DISMISS] answer: Back on the
 * window appearing, then [dismissAfterMs] later Home if the dialog is
 * still up, then, for sleep, the lock-screen action. Within
 * [wakeGraceMs] of the screen coming on, sleep is downgraded to dismiss.
 */
class PowerDialogAnswerer(
    private val now: () -> Long,
    private val schedule: (Long, Runnable) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val report: (choice: String, found: Boolean, detail: String) -> Unit,
    private val actions: GlobalActions,
    private val answeredForMs: Long = 3000,
    private val missAfterMs: Long = 1500,
    private val dismissAfterMs: Long = 500,
    private val wakeGraceMs: Long = 5000,
) {
    @Volatile
    var packageName: String = ""

    @Volatile
    var choice: String = PowerDialog.DEFAULT_CHOICE

    private var answeredUntil = 0L
    private var miss: Runnable? = null
    private var follow: Runnable? = null
    private var wokeAt = Long.MIN_VALUE / 2

    /** The screen came on: a dialog right after it is the wake-up press. */
    fun screenOn() {
        wokeAt = now()
    }

    private fun isGlobal(choice: String) =
        choice == PowerDialog.SLEEP || choice == PowerDialog.DISMISS

    /** Whether the service should ask for window-content events at all:
     *  only a view id has to be looked for in the dialog. */
    fun wantsContent(): Boolean = packageName.isNotEmpty() && !isGlobal(choice)

    fun concerns(pkg: String): Boolean = packageName.isNotEmpty() && pkg == packageName

    /**
     * An event from the dialog's package. [appeared] is a window-state
     * change (the dialog opening), anything else a content change in it.
     * [root] is read only when a view-id answer is due. True when the
     * dialog was answered by this call.
     */
    fun onWindow(pkg: String, appeared: Boolean, root: () -> DialogNode?): Boolean {
        if (!concerns(pkg)) return false
        if (now() < answeredUntil) return false
        val choice = choice
        if (isGlobal(choice)) {
            if (!appeared) return false
            answeredUntil = now() + answeredForMs
            val justWoke = now() - wokeAt < wakeGraceMs
            val sleep = choice == PowerDialog.SLEEP && !justWoke
            actions.back()
            val pending = Runnable {
                follow = null
                val stillUp = actions.dialogShowing(pkg) && !actions.home()
                when {
                    sleep -> report(PowerDialog.SLEEP, actions.lockScreen(), "")
                    choice == PowerDialog.SLEEP ->
                        report(PowerDialog.DISMISS, !stillUp, "the screen just woke, so no sleep")
                    else -> report(PowerDialog.DISMISS, !stillUp, "")
                }
            }
            follow?.let(cancel)
            follow = pending
            schedule(dismissAfterMs, pending)
            return true
        }
        val tree = root()
        val found = tree != null && answerDialog(tree, "$pkg:id/$choice")
        if (found) {
            answeredUntil = now() + answeredForMs
            miss?.let(cancel)
            miss = null
            report(choice, true, "")
            return true
        }
        if (appeared && miss == null) {
            val pending = Runnable {
                miss = null
                report(choice, false, "")
            }
            miss = pending
            schedule(missAfterMs, pending)
        }
        return false
    }
}

/** [DialogNode] over a real node. Children are walked by Android's own
 *  id search, which needs FLAG_REPORT_VIEW_IDS (set in the XML). */
private class NodeInfoNode(private val info: AccessibilityNodeInfo) : DialogNode {
    override val isClickable: Boolean get() = info.isClickable
    override val parent: DialogNode? get() = info.parent?.let { NodeInfoNode(it) }

    override fun findByViewId(id: String): List<DialogNode> =
        runCatching { info.findAccessibilityNodeInfosByViewId(id) }
            .getOrNull()
            ?.map { NodeInfoNode(it) }
            ?: emptyList()

    override fun click(): Boolean =
        runCatching { info.performAction(AccessibilityNodeInfo.ACTION_CLICK) }.getOrDefault(false)

    override fun focus(): Boolean =
        runCatching { info.performAction(AccessibilityNodeInfo.ACTION_FOCUS) }.getOrDefault(false)
}
