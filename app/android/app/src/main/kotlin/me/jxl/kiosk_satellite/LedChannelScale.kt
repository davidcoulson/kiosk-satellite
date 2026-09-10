package me.jxl.kiosk_satellite

/**
 * Maps a Home Assistant colour channel (0..255) down to the panel's safe
 * low-drive region. ha-paneld's own hardware probe (see led_ioctl.h's header
 * comment) found 0..15 to reproduce colour accurately on the unit they
 * tested; higher raw values drive the LED into a region where hue visibly
 * shifts. This is that stub, pulled out on its own so it can be pinned by a
 * unit test independent of [LedBridge] (which needs a live Context/
 * BinaryMessenger to construct) — a real per-panel calibration curve is
 * still pending on-device measurement.
 */
internal object LedChannelScale {
    const val SAFE_CHANNEL_MAX = 15

    fun toHardware(v: Int): Int = (v.coerceIn(0, 255) * SAFE_CHANNEL_MAX) / 255
}
