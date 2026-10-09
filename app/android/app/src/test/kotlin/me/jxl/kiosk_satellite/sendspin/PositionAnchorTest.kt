package me.jxl.kiosk_satellite.sendspin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PositionAnchorTest {
    @Test fun nothingAdoptedLeavesTheEngineInCharge() {
        assertNull(PositionAnchor().current(now = 1_000, durationMs = 290_000))
    }

    @Test fun anAdoptedPositionKeepsMovingWhileTheStreamPlays() {
        val anchor = PositionAnchor()
        anchor.set(145_000, now = 10_000, running = true)
        assertEquals(145_000L, anchor.current(now = 10_000, durationMs = 290_000))
        // Issue #915: tied to the engine, which had stopped at the duration,
        // every push sent 145 s again.
        assertEquals(175_000L, anchor.current(now = 40_000, durationMs = 290_000))
    }

    @Test fun itStopsAtTheDurationAndRunsFreeWithoutOne() {
        val anchor = PositionAnchor()
        anchor.set(280_000, now = 0, running = true)
        assertEquals(290_000L, anchor.current(now = 60_000, durationMs = 290_000))
        assertEquals(340_000L, anchor.current(now = 60_000, durationMs = 0))
    }

    @Test fun aStoppedStreamHoldsThePosition() {
        val anchor = PositionAnchor()
        anchor.set(30_000, now = 0, running = true)
        anchor.setRunning(false, now = 5_000)
        assertEquals(35_000L, anchor.current(now = 60_000, durationMs = 0))
        anchor.setRunning(true, now = 60_000)
        assertEquals(37_000L, anchor.current(now = 62_000, durationMs = 0))
    }

    @Test fun anAdoptionWhileStoppedWaitsForTheStream() {
        val anchor = PositionAnchor()
        anchor.set(30_000, now = 0, running = false)
        assertEquals(30_000L, anchor.current(now = 9_000, durationMs = 0))
        anchor.setRunning(true, now = 10_000)
        assertEquals(31_000L, anchor.current(now = 11_000, durationMs = 0))
    }

    @Test fun aServerReportClearsIt() {
        val anchor = PositionAnchor()
        anchor.set(30_000, now = 0, running = true)
        anchor.clear()
        assertFalse(anchor.isSet)
        assertNull(anchor.current(now = 1_000, durationMs = 0))
    }

    @Test fun theStreamRestartAfterAPreviousStartsTheTrackOver() {
        val anchor = PositionAnchor()
        anchor.set(145_000, now = 0, running = true)
        anchor.previousSent(now = 20_000)
        assertTrue(anchor.onStreamStart(now = 21_000))
        // Still through the silence before the music, then running.
        assertEquals(0L, anchor.current(now = 22_500, durationMs = 290_000))
        anchor.setRunning(true, now = 23_000)
        assertEquals(2_000L, anchor.current(now = 25_000, durationMs = 290_000))
        // Only the first start after the command counts.
        assertFalse(anchor.onStreamStart(now = 22_000))
    }

    @Test fun aStreamStartWithoutAPreviousChangesNothing() {
        val anchor = PositionAnchor()
        assertFalse(anchor.onStreamStart(now = 1_000))
        assertNull(anchor.current(now = 1_000, durationMs = 0))
    }

    @Test fun aLateStreamStartIsNotThePreviousRestart() {
        val anchor = PositionAnchor()
        anchor.previousSent(now = 0)
        assertFalse(anchor.onStreamStart(now = PositionAnchor.PREVIOUS_RESTART_WINDOW_MS + 1))
    }

    @Test fun aPreviousThatChangedTracksLeavesItToTheNewMetadata() {
        val anchor = PositionAnchor()
        anchor.previousSent(now = 0)
        // The prior track's report lands first.
        anchor.clear()
        assertFalse(anchor.onStreamStart(now = 500))
    }
}
