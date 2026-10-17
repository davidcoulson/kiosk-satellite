package me.jxl.kiosk_satellite

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ProximitySensorTest {
    @Test
    fun px30ReadingsAlternateBetweenFarAndNear() {
        val threshold = proximityNearThreshold(9f, 9f)
        val readings = listOf(1f, 0f, 1f, 0f, 1f, 0f)
        assertEquals(
            listOf(false, true, false, true, false, true),
            readings.map { it < threshold },
        )
    }

    @Test
    fun binarySensorsRecognizeNearAndFarAcrossRanges() {
        for (range in listOf(9f, 5f, 1f, 0.4f)) {
            val threshold = proximityNearThreshold(range, range)
            assertTrue(0f < threshold, "near at range $range")
            assertFalse(range < threshold, "far at range $range")
            assertFalse(1f < threshold, "far flag at range $range")
        }
    }

    @Test
    fun continuousSensorsKeepTheirDistanceRange() {
        val threshold = proximityNearThreshold(5f, 0.1f)
        assertTrue(2f < threshold)
        assertTrue(4.9f < threshold)
        assertFalse(5f < threshold)
        assertFalse(6f < threshold)
    }

    @Test
    fun missingRangeStillDistinguishesBinaryFlags() {
        for (range in listOf(0f, -1f)) {
            val threshold = proximityNearThreshold(range, 0f)
            assertTrue(0f < threshold)
            assertFalse(1f < threshold)
        }
    }

    /** Feeds readings 200 ms apart, the rate the app registers at. */
    private class Feed(maximumRange: Float, resolution: Float) {
        private val c = ProximityClassifier(maximumRange, resolution)
        var nanos = 0L

        fun read(value: Float): Boolean {
            nanos += 200_000_000L
            return c.near(value, nanos)
        }

        fun readAll(values: List<Float>) = values.map(::read)
    }

    @Test
    fun rawCountsRisingWithProximityReadAsNear() {
        // NSPanel Pro (#980): range 9, resolution 9, about 50 at rest.
        val f = Feed(9f, 9f)
        val rest = listOf(50f, 48f, 49f, 50f, 48f)
        assertEquals(List(rest.size) { false }, f.readAll(rest))
        // A hand waved in from 20 cm and back out again.
        val wave = listOf(53f, 63f, 92f, 150f, 272f, 789f, 531f, 70f, 52f, 49f)
        assertEquals(
            listOf(false, false, true, true, true, true, true, true, false, false),
            f.readAll(wave),
        )
    }

    @Test
    fun rawCountsIgnoreRestingBlipsAndDips() {
        val f = Feed(9f, 9f)
        f.readAll(listOf(47f, 46f, 48f, 47f, 50f, 47f))
        // The odd blip to 60 the reporter saw is noise, not an approach.
        assertFalse(f.read(60f))
        assertFalse(f.read(47f))
        // A low dip must not drag the resting level down so far that the
        // usual resting readings read as near afterwards.
        assertFalse(f.read(30f))
        assertEquals(List(6) { false }, f.readAll(listOf(47f, 48f, 50f, 46f, 49f, 47f)))
        assertTrue(f.read(150f))
    }

    @Test
    fun rawCountsFollowSlowDriftWithoutTriggering() {
        val f = Feed(9f, 9f)
        var value = 1000f
        repeat(2000) {
            value += 0.2f
            assertFalse(f.read(value), "drift at $value")
        }
        assertTrue(f.read(value * 1.4f))
    }

    @Test
    fun rawCountsLearnALiftedCoverWithinSeconds() {
        val f = Feed(9f, 9f)
        f.readAll(List(5) { 300f })
        // The cover comes off: the resting level drops to about 50.
        assertEquals(List(50) { false }, f.readAll(List(50) { if (it % 2 == 0) 50f else 48f }))
        assertTrue(f.read(150f))
    }

    @Test
    fun aNearThatNeverEndsBecomesTheRestingLevel() {
        val f = Feed(9f, 9f)
        f.readAll(listOf(47f, 48f, 47f))
        assertTrue(f.read(120f))
        // The readings settle on a new level with nothing in front.
        var near = true
        repeat(299) { near = f.read(if (it % 2 == 0) 119f else 121f) }
        assertTrue(near, "still near before a minute")
        assertFalse(f.read(120f), "released after a minute")
        assertFalse(f.read(121f))
        assertTrue(f.read(400f))
    }

    @Test
    fun rawCountsFirstJumpFromALowRestingLevelIsNear() {
        val f = Feed(9f, 9f)
        assertFalse(f.read(5f))
        assertTrue(f.read(150f))
        assertFalse(f.read(6f))
    }

    @Test
    fun px30FlagsKeepTheirDistanceMeaning() {
        assertEquals(
            listOf(false, true, false, true),
            Feed(9f, 9f).readAll(listOf(1f, 0f, 1f, 0f)),
        )
    }

    @Test
    fun aFarReadingJustPastTheRangeIsStillADistance() {
        assertEquals(
            listOf(false, true, false),
            Feed(5f, 1f).readAll(listOf(6f, 0f, 6f)),
        )
    }
}
