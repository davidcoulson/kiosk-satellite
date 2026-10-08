package me.jxl.kiosk_satellite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Answering a vendor's power dialog: which view gets the click
 *  (answerDialog), and when the service answers at all
 *  (PowerDialogAnswerer): once per appearance, with a late miss report. */
class PowerDialogTest {
    private val pkg = "com.htc.closedialog"
    private val sleep = "$pkg:id/rl_sleep"

    /** A view tree in memory. [clicks] and [focuses] record what landed. */
    private class Node(
        val id: String? = null,
        override val isClickable: Boolean = false,
        val clickWorks: Boolean = true,
        /** A button that answers a click only while it holds focus. */
        val clickNeedsFocus: Boolean = false,
        val focusWorks: Boolean = true,
        children: List<Node> = emptyList(),
    ) : DialogNode {
        override var parent: Node? = null
        val children = children.onEach { it.parent = this }
        val clicks = mutableListOf<String>()
        val focuses = mutableListOf<String>()

        override fun findByViewId(id: String): List<DialogNode> =
            (if (this.id == id) listOf(this) else emptyList()) +
                children.flatMap { it.findByViewId(id) }

        private var focused = false

        override fun click(): Boolean {
            root().clicks.add(id ?: "<row>")
            return clickWorks && (!clickNeedsFocus || focused)
        }

        override fun focus(): Boolean {
            root().focuses.add(id ?: "<row>")
            focused = focusWorks
            return focusWorks
        }

        private fun root(): Node = parent?.root() ?: this
    }

    /** The HY260's dialog, roughly: four rows, each a clickable layout
     *  carrying the id, Shutdown focused by default. */
    private fun hy260(sleepRow: Node = Node(sleep, isClickable = true)) = Node(
        children = listOf(
            Node("$pkg:id/rl_shutdown", isClickable = true),
            Node("$pkg:id/rl_reboot", isClickable = true),
            sleepRow,
            Node("$pkg:id/rl_speaker", isClickable = true),
        ),
    )

    @Test
    fun `the clickable view with the id gets the click`() {
        val root = hy260()
        assertTrue(answerDialog(root, sleep))
        assertEquals(listOf(sleep), root.clicks)
        assertTrue(root.focuses.isEmpty())
    }

    @Test
    fun `a label inside a clickable row clicks the row`() {
        val label = Node(sleep)
        val root = hy260(Node(isClickable = true, children = listOf(label)))
        assertTrue(answerDialog(root, sleep))
        assertEquals(listOf("<row>"), root.clicks)
    }

    @Test
    fun `nothing clickable above it is focused and then clicked`() {
        val root = hy260(Node(sleep))
        assertTrue(answerDialog(root, sleep))
        assertEquals(listOf(sleep), root.focuses)
        assertEquals(listOf(sleep), root.clicks)
    }

    @Test
    fun `a refused click falls through to the ancestor and then to focus`() {
        val label = Node(sleep, isClickable = true, clickNeedsFocus = true)
        val row = Node(isClickable = true, clickWorks = false, children = listOf(label))
        val root = hy260(row)
        assertTrue(answerDialog(root, sleep))
        assertEquals(listOf(sleep, "<row>", sleep), root.clicks)
        assertEquals(listOf(sleep), root.focuses)
    }

    @Test
    fun `a missing id clicks nothing`() {
        val root = hy260()
        assertFalse(answerDialog(root, "$pkg:id/rl_hibernate"))
        assertTrue(root.clicks.isEmpty())
        assertTrue(root.focuses.isEmpty())
    }

    // ── The answerer ─────────────────────────────────────────────────

    private var now = 10_000L
    private var timer: Runnable? = null
    private val reports = mutableListOf<Pair<String, Boolean>>()
    private val details = mutableListOf<String>()

    /** The screen as a whole: what was asked of it, and whether the
     *  dialog is still up when asked. */
    private class Screen(
        var showing: Boolean = true,
        var lockWorks: Boolean = true,
    ) : GlobalActions {
        val done = mutableListOf<String>()
        override fun back(): Boolean { done.add("back"); return true }
        override fun home(): Boolean { done.add("home"); showing = false; return true }
        override fun lockScreen(): Boolean { done.add("lock"); return lockWorks }
        override fun dialogShowing(pkg: String) = showing
    }

    private val screen = Screen()
    private val answerer = PowerDialogAnswerer(
        now = { now },
        schedule = { _, run -> timer = run },
        cancel = { run -> if (timer === run) timer = null },
        report = { choice, found, detail -> reports.add(choice to found); details.add(detail) },
        actions = screen,
    ).apply { packageName = pkg; choice = "rl_sleep" }

    private fun elapseMiss() {
        val run = timer
        timer = null
        run?.run()
    }

    /** The dismissal's follow-up, half a second after Back. */
    private fun elapseFollow() = elapseMiss()

    @Test
    fun `nothing is read while no package is configured`() {
        answerer.packageName = ""
        assertFalse(answerer.wantsContent())
        var read = false
        assertFalse(answerer.onWindow(pkg, true) { read = true; hy260() })
        assertFalse(read)
        assertTrue(reports.isEmpty())
    }

    @Test
    fun `another package's windows are never read`() {
        assertTrue(answerer.wantsContent())
        var read = false
        assertFalse(answerer.onWindow("com.plexapp.android", true) { read = true; hy260() })
        assertFalse(read)
        assertNull(timer)
    }

    @Test
    fun `the dialog is answered once per appearance`() {
        val root = hy260()
        assertTrue(answerer.onWindow(pkg, true) { root })
        assertEquals(listOf("rl_sleep" to true), reports)
        // The click's own content changes, and a second state event.
        now += 500
        assertFalse(answerer.onWindow(pkg, false) { root })
        assertFalse(answerer.onWindow(pkg, true) { root })
        assertEquals(listOf(sleep), root.clicks)
        assertNull(timer)
        // The next evening's press is a new appearance.
        now += 3000
        assertTrue(answerer.onWindow(pkg, true) { root })
        assertEquals(listOf(sleep, sleep), root.clicks)
    }

    @Test
    fun `buttons that inflate after the window is announced are still pressed`() {
        val empty = Node()
        val root = hy260()
        assertFalse(answerer.onWindow(pkg, true) { empty })
        assertTrue(reports.isEmpty()) // not yet a miss
        now += 200
        assertTrue(answerer.onWindow(pkg, false) { root })
        assertEquals(listOf("rl_sleep" to true), reports)
        assertNull(timer) // the miss report was cancelled
    }

    @Test
    fun `a dialog with no such button is reported once, late`() {
        val empty = Node()
        assertFalse(answerer.onWindow(pkg, true) { empty })
        assertFalse(answerer.onWindow(pkg, false) { empty })
        assertFalse(answerer.onWindow(pkg, true) { empty })
        assertTrue(reports.isEmpty())
        elapseMiss()
        assertEquals(listOf("rl_sleep" to false), reports)
        // Retries after the report stay quiet until one lands.
        assertFalse(answerer.onWindow(pkg, false) { empty })
        assertEquals(1, reports.size)
    }

    @Test
    fun `the choice names the view, under the dialog's package`() {
        answerer.choice = "rl_reboot"
        val root = hy260()
        assertTrue(answerer.onWindow(pkg, true) { root })
        assertEquals(listOf("$pkg:id/rl_reboot"), root.clicks)
        assertEquals(listOf("rl_reboot" to true), reports)
    }

    @Test
    fun `a window the service cannot read is not an answer`() {
        assertFalse(answerer.onWindow(pkg, true) { null })
        elapseMiss()
        assertEquals(listOf("rl_sleep" to false), reports)
    }

    // ── Sleep and dismiss ────────────────────────────────────────────

    @Test
    fun `sleep is the default and needs no content events`() {
        val fresh = PowerDialogAnswerer({ now }, { _, _ -> }, {}, { _, _, _ -> }, screen)
        assertEquals("sleep", fresh.choice)
        fresh.packageName = pkg
        assertFalse(fresh.wantsContent())
        fresh.choice = "rl_reboot"
        assertTrue(fresh.wantsContent())
    }

    @Test
    fun `sleep closes the dialog and then locks the screen`() {
        answerer.choice = "sleep"
        var read = false
        screen.showing = false // Back took
        assertTrue(answerer.onWindow(pkg, true) { read = true; hy260() })
        assertFalse(read) // no view is looked for
        assertEquals(listOf("back"), screen.done)
        assertTrue(reports.isEmpty())
        elapseFollow()
        assertEquals(listOf("back", "lock"), screen.done)
        assertEquals(listOf("sleep" to true), reports)
        assertEquals(listOf(""), details)
    }

    @Test
    fun `a dialog Back did not close gets Home first`() {
        answerer.choice = "sleep"
        assertTrue(answerer.onWindow(pkg, true) { hy260() })
        elapseFollow()
        assertEquals(listOf("back", "home", "lock"), screen.done)
        assertEquals(listOf("sleep" to true), reports)
    }

    @Test
    fun `a refused lock is reported as not answered`() {
        answerer.choice = "sleep"
        screen.showing = false
        screen.lockWorks = false
        assertTrue(answerer.onWindow(pkg, true) { hy260() })
        elapseFollow()
        assertEquals(listOf("sleep" to false), reports)
    }

    @Test
    fun `dismiss only closes the dialog`() {
        answerer.choice = "dismiss"
        screen.showing = false
        assertTrue(answerer.onWindow(pkg, true) { hy260() })
        elapseFollow()
        assertEquals(listOf("back"), screen.done)
        assertEquals(listOf("dismiss" to true), reports)
    }

    @Test
    fun `right after the screen wakes, sleep only dismisses`() {
        answerer.choice = "sleep"
        screen.showing = false
        answerer.screenOn()
        now += 2000
        assertTrue(answerer.onWindow(pkg, true) { hy260() })
        elapseFollow()
        assertEquals(listOf("back"), screen.done)
        assertEquals(listOf("dismiss" to true), reports)
        assertEquals(listOf("the screen just woke, so no sleep"), details)
        // Six seconds on, the power key means sleep again.
        now += 6000
        assertTrue(answerer.onWindow(pkg, true) { hy260() })
        elapseFollow()
        assertEquals(listOf("back", "back", "lock"), screen.done)
        assertEquals("sleep" to true, reports.last())
    }

    @Test
    fun `content events never answer sleep, and one appearance sleeps once`() {
        answerer.choice = "sleep"
        screen.showing = false
        assertFalse(answerer.onWindow(pkg, false) { hy260() })
        assertTrue(screen.done.isEmpty())
        assertTrue(answerer.onWindow(pkg, true) { hy260() })
        now += 300
        assertFalse(answerer.onWindow(pkg, true) { hy260() })
        elapseFollow()
        assertEquals(listOf("back", "lock"), screen.done)
        assertEquals(1, reports.size)
    }
}
