package me.jxl.kiosk_satellite

import kotlin.test.Test
import kotlin.test.assertEquals

class LedChannelScaleTest {
    @Test
    fun mapsHomeAssistantRangeOntoTheSafeDriveRegion() {
        assertEquals(0, LedChannelScale.toHardware(0))
        assertEquals(15, LedChannelScale.toHardware(255))
        assertEquals(7, LedChannelScale.toHardware(128))
    }

    @Test
    fun clampsOutOfRangeValues() {
        assertEquals(0, LedChannelScale.toHardware(-10))
        assertEquals(15, LedChannelScale.toHardware(1000))
    }

    @Test
    fun neverExceedsTheSafeMaximum() {
        for (v in 0..255) {
            val hw = LedChannelScale.toHardware(v)
            assertEquals(hw.coerceIn(0, LedChannelScale.SAFE_CHANNEL_MAX), hw)
        }
    }
}
