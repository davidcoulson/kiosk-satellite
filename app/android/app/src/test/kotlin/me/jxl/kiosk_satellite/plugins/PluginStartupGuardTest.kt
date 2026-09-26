package me.jxl.kiosk_satellite.plugins

import org.junit.Assert.assertEquals
import org.junit.Test

/** The plugin startup guard: one incomplete start is a strike, an app
 *  update in between is none, and it takes two in a row to disable. */
class PluginStartupGuardTest {
    private val v1 = 1_000L
    private val v2 = 2_000L

    @Test
    fun aCompletedStartupCountsNothing() {
        assertEquals(0, PluginBridge.startupVerdict(pending = false, startedUnder = v1, now = v1, strikes = 1))
    }

    @Test
    fun anUpdateDuringStartupIsNotAFailure() {
        assertEquals(0, PluginBridge.startupVerdict(pending = true, startedUnder = v1, now = v2, strikes = 1))
    }

    @Test
    fun oneIncompleteStartIsAStrikeButNotEnoughToDisable() {
        val strikes = PluginBridge.startupVerdict(pending = true, startedUnder = v1, now = v1, strikes = 0)
        assertEquals(1, strikes)
        assert(strikes < PluginBridge.STARTUP_STRIKES)
    }

    @Test
    fun twoInARowDisable() {
        val strikes = PluginBridge.startupVerdict(pending = true, startedUnder = v1, now = v1, strikes = 1)
        assertEquals(PluginBridge.STARTUP_STRIKES, strikes)
    }
}
