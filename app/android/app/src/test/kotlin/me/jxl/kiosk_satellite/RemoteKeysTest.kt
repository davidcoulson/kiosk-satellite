package me.jxl.kiosk_satellite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Remote key mappings: which presses the service swallows, and which
 *  action each one fires (RemoteKeyMatcher), plus the settings parse. */
class RemoteKeysTest {
    private val home = 3
    private val f4 = 134
    private val menu = 82

    private var timer: Runnable? = null
    private val fired = mutableListOf<String>()
    private val matcher = RemoteKeyMatcher(
        longPressMs = 500,
        schedule = { _, run -> timer = run },
        cancel = { run -> if (timer === run) timer = null },
        fire = { fired.add(it.id) },
    )

    private fun mapping(id: String, code: Int, long: Boolean = false) =
        RemoteKeyMapping(id, code, long, "launch_app", "com.example")

    private fun elapseLongPress() {
        val run = timer
        timer = null
        run?.run()
    }

    @Test
    fun `an unmapped key passes through untouched`() {
        matcher.mappings = listOf(mapping("home", home))
        assertFalse(matcher.onDown(menu, 0))
        assertFalse(matcher.onUp(menu))
        assertTrue(fired.isEmpty())
    }

    @Test
    fun `a short-only key fires on the way down and swallows the whole press`() {
        matcher.mappings = listOf(mapping("home", home))
        assertTrue(matcher.onDown(home, 0))
        assertEquals(listOf("home"), fired)
        assertTrue(matcher.onDown(home, 1)) // a repeat of the owned press
        assertTrue(matcher.onUp(home))
        assertEquals(listOf("home"), fired)
        assertNull(timer)
    }

    @Test
    fun `with a long mapping a quick press fires the short one on release`() {
        matcher.mappings = listOf(mapping("short", home), mapping("long", home, long = true))
        assertTrue(matcher.onDown(home, 0))
        assertTrue(fired.isEmpty())
        assertTrue(matcher.onUp(home))
        assertEquals(listOf("short"), fired)
        assertNull(timer)
    }

    @Test
    fun `a held key fires the long mapping once and not the short one`() {
        matcher.mappings = listOf(mapping("short", home), mapping("long", home, long = true))
        matcher.onDown(home, 0)
        elapseLongPress()
        assertEquals(listOf("long"), fired)
        matcher.onDown(home, 1)
        assertTrue(matcher.onUp(home))
        assertEquals(listOf("long"), fired)
    }

    @Test
    fun `a long-only key swallows a quick press and fires nothing`() {
        matcher.mappings = listOf(mapping("long", f4, long = true))
        assertTrue(matcher.onDown(f4, 0))
        assertTrue(matcher.onUp(f4))
        assertTrue(fired.isEmpty())
    }

    @Test
    fun `the tail of a press that began unmapped is left alone`() {
        matcher.mappings = listOf(mapping("home", home))
        assertFalse(matcher.onDown(home, 3))
        assertFalse(matcher.onUp(home))
        assertTrue(fired.isEmpty())
    }

    @Test
    fun `a second key pressed mid-hold abandons the first long press`() {
        matcher.mappings = listOf(mapping("long", home, long = true), mapping("gear", f4))
        matcher.onDown(home, 0)
        assertTrue(matcher.onDown(f4, 0))
        elapseLongPress() // the cancelled timer is gone
        assertEquals(listOf("gear"), fired)
        assertFalse(matcher.onUp(home)) // no longer owned
    }

    @Test
    fun `a lost release does not swallow the next press`() {
        matcher.mappings = listOf(mapping("home", home))
        matcher.onDown(home, 0)
        // No onUp: the release went elsewhere. The next press still fires.
        assertTrue(matcher.onDown(home, 0))
        assertEquals(listOf("home", "home"), fired)
    }

    @Test
    fun `only remote_key entries with a key code are parsed`() {
        val json = """
            [
              {"id": "a", "trigger": {"type": "remote_key", "keyCode": 3},
               "action": {"type": "launch_app", "package": "com.spocky.projengmenu"}},
              {"id": "b", "trigger": {"type": "remote_key", "keyCode": 134, "longPress": true},
               "action": {"type": "android_settings"}},
              {"id": "c", "trigger": {"type": "corner_taps", "corner": "tl", "taps": 3},
               "action": {"type": "screensaver"}},
              {"id": "d", "trigger": {"type": "remote_key"}, "action": {"type": "screensaver"}},
              {"id": "e", "trigger": {"type": "remote_key", "keyCode": 82},
               "action": {"type": "open_uri", "uri": "plezy://home"}},
              "junk"
            ]
        """.trimIndent()
        val parsed = parseRemoteKeyMappings(json)
        assertEquals(listOf("a", "b", "e"), parsed.map { it.id })
        assertEquals(RemoteKeyMapping("a", 3, false, "launch_app", "com.spocky.projengmenu"), parsed[0])
        assertEquals(RemoteKeyMapping("b", 134, true, "android_settings", null), parsed[1])
        assertEquals("plezy://home", parsed[2].target)
    }

    @Test
    fun `unparseable settings read as no mappings`() {
        assertTrue(parseRemoteKeyMappings("{nope").isEmpty())
        assertTrue(parseRemoteKeyMappings(null).isEmpty())
        assertTrue(parseRemoteKeyMappings("[]").isEmpty())
    }
}
