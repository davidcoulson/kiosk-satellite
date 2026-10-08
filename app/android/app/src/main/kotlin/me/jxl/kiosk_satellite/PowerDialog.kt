package me.jxl.kiosk_satellite

import android.content.Context
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
 * power menu but to the vendor's: the HY260 opens
 * com.htc.closedialog/.MainActivity, with Shutdown focused and a fifteen
 * second countdown that shuts the box down when nobody picks anything
 * else. A shutdown ends Kiosk Satellite until someone powers the box on
 * again, so the family's power-button press should put the projector to
 * sleep instead. Nothing an app can do reaches another app's buttons -
 * except an accessibility service, which [KioskAccessibilityService]
 * already is for remote keys: with window content access it sees the
 * dialog's views and may click one of them.
 *
 * device.power_dialog_package names the dialog's package and
 * device.power_dialog_choice the view id of the button to press (rl_sleep
 * on the HY260; the full id is package:id/choice). The two are pushed from
 * Dart ([RemoteKeysBridge]) and seeded from the settings mirror when the
 * service binds, so the dialog is answered from boot before Dart has run.
 *
 * The service watches window-state changes anyway; while a package is
 * configured it also asks for window-content changes
 * ([KioskAccessibilityService.watchContent]), since a dialog's buttons
 * are not always inflated by the time its window is announced. Each
 * appearance is answered once: after a click lands, events from the dialog
 * are ignored for a few seconds, so the content changes the click itself
 * causes do not press the button again. A dialog whose button never turns
 * up is logged, once, after the retries have had their chance.
 */
object PowerDialog {
    private const val TAG = "PowerDialog"
    private const val PREFS = "FlutterSharedPreferences"
    private const val PACKAGE_KEY = "flutter.ks.device.power_dialog_package"
    private const val CHOICE_KEY = "flutter.ks.device.power_dialog_choice"
    const val DEFAULT_CHOICE = "rl_sleep"

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var configured = false

    @Volatile
    private var bridge: RemoteKeysBridge? = null

    private val answerer = PowerDialogAnswerer(
        now = { SystemClock.uptimeMillis() },
        schedule = { delay, run -> main.postDelayed(run, delay) },
        cancel = { run -> main.removeCallbacks(run) },
        report = { choice, found -> report(choice, found) },
    )

    fun attach(bridge: RemoteKeysBridge) {
        this.bridge = bridge
    }

    /** The service bound: read the mirror if Dart has not spoken yet, and
     *  ask for content events if a package is configured. */
    fun serviceConnected(service: KioskAccessibilityService) {
        if (!configured) seed(service)
        service.watchContent(answerer.wantsContent())
    }

    private fun seed(context: Context) {
        try {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            answerer.packageName = prefs.getString(PACKAGE_KEY, null) ?: ""
            answerer.choice = prefs.getString(CHOICE_KEY, null) ?: DEFAULT_CHOICE
        } catch (e: Exception) {
            Log.w(TAG, "could not read the power dialog settings: $e")
        }
    }

    /** Dart's push: the dialog's package (empty = off) and the button. */
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

    private fun report(choice: String, found: Boolean) {
        if (found) {
            Log.i(TAG, "answered the power dialog with $choice")
        } else {
            Log.w(TAG, "power dialog shown but $choice not found")
        }
        bridge?.powerDialog(choice, found)
    }
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
 * answered once: [answeredForMs] after a click, further events from the
 * dialog are ignored. A window-state change that finds no button is not
 * yet a miss - the buttons may still be inflating, and the content
 * changes that follow retry - so the miss is reported only when nothing
 * has landed [missAfterMs] later.
 */
class PowerDialogAnswerer(
    private val now: () -> Long,
    private val schedule: (Long, Runnable) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val report: (choice: String, found: Boolean) -> Unit,
    private val answeredForMs: Long = 3000,
    private val missAfterMs: Long = 1500,
) {
    @Volatile
    var packageName: String = ""

    @Volatile
    var choice: String = PowerDialog.DEFAULT_CHOICE

    private var answeredUntil = 0L
    private var miss: Runnable? = null

    /** Whether the service should ask for window-content events at all. */
    fun wantsContent(): Boolean = packageName.isNotEmpty()

    fun concerns(pkg: String): Boolean = packageName.isNotEmpty() && pkg == packageName

    /**
     * An event from the dialog's package. [appeared] is a window-state
     * change (the dialog opening), anything else a content change in it.
     * [root] is read only when an answer is due. True when the button
     * was clicked by this call.
     */
    fun onWindow(pkg: String, appeared: Boolean, root: () -> DialogNode?): Boolean {
        if (!concerns(pkg)) return false
        if (now() < answeredUntil) return false
        val choice = choice
        val tree = root()
        val found = tree != null && answerDialog(tree, "$pkg:id/$choice")
        if (found) {
            answeredUntil = now() + answeredForMs
            miss?.let(cancel)
            miss = null
            report(choice, true)
            return true
        }
        if (appeared && miss == null) {
            val pending = Runnable {
                miss = null
                report(choice, false)
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
