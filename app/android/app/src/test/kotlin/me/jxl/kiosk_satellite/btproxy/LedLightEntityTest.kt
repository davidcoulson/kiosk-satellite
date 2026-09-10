package me.jxl.kiosk_satellite.btproxy

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Wire-format coverage for the [EspEntity.Light] `colorCapable` addition
 * (the panel RGB LED entity): a regression pin that the existing Screen
 * light (colorCapable=false) encodes byte-for-byte as it always has, plus
 * the new RGB fields for a colour light. Field numbers are asserted
 * directly against known values from aioesphomeapi's api.proto (fetched
 * and cross-checked while implementing this), not just round-tripped
 * against our own encoder.
 */
class LedLightEntityTest {

    private fun screen() = EspEntity.Light(objectId = "screen", name = "Screen")

    private fun rgbLed() = EspEntity.Light(
        objectId = "rgb_led",
        name = "RGB LED",
        colorCapable = true,
    )

    private fun rgbLedWithEffects() = EspEntity.Light(
        objectId = "rgb_led",
        name = "RGB LED",
        colorCapable = true,
        effects = listOf("Pulse", "Strobe", "Random", "Flicker"),
    )

    @Test
    fun `screen light description is unchanged by the colorCapable addition`() {
        val (type, payload) = EntityCodec.describe(screen(), "ks-test")
        assertEquals(Msg.LIST_ENTITIES_LIGHT_RESPONSE, type)

        var sawLegacyBrightness = false
        var sawLegacyRgb = false
        var colorMode = -1
        val r = ProtoReader(payload)
        while (r.next()) when (r.field) {
            5 -> sawLegacyBrightness = r.asBool()
            6 -> sawLegacyRgb = r.asBool()
            12 -> colorMode = r.asInt()
        }
        assertTrue(sawLegacyBrightness)
        assertFalse(sawLegacyRgb)
        assertEquals(3, colorMode) // COLOR_MODE_BRIGHTNESS
    }

    @Test
    fun `rgb led description advertises COLOR_MODE_RGB and the legacy rgb bit`() {
        val (type, payload) = EntityCodec.describe(rgbLed(), "ks-test")
        assertEquals(Msg.LIST_ENTITIES_LIGHT_RESPONSE, type)

        var sawLegacyBrightness = false
        var sawLegacyRgb = false
        var colorMode = -1
        val r = ProtoReader(payload)
        while (r.next()) when (r.field) {
            5 -> sawLegacyBrightness = r.asBool()
            6 -> sawLegacyRgb = r.asBool()
            12 -> colorMode = r.asInt()
        }
        assertTrue(sawLegacyBrightness)
        assertTrue(sawLegacyRgb)
        assertEquals(35, colorMode) // COLOR_MODE_RGB
    }

    @Test
    fun `screen state carries brightness, not rgb`() {
        val (type, payload) = EntityCodec.state(
            screen(),
            mapOf("on" to true, "brightness" to 0.75),
        )!!
        assertEquals(Msg.LIGHT_STATE_RESPONSE, type)

        var on = false
        var brightness = -1f
        var colorMode = -1
        var sawRed = false
        val r = ProtoReader(payload)
        while (r.next()) when (r.field) {
            2 -> on = r.asBool()
            3 -> brightness = r.asFloat()
            4 -> sawRed = true
            11 -> colorMode = r.asInt()
        }
        assertTrue(on)
        assertEquals(0.75f, brightness)
        assertEquals(3, colorMode)
        assertFalse(sawRed)
    }

    @Test
    fun `rgb led state carries full-scale brightness and rgb fractions`() {
        val (type, payload) = EntityCodec.state(
            rgbLed(),
            mapOf("on" to true, "r" to 255, "g" to 128, "b" to 0),
        )!!
        assertEquals(Msg.LIGHT_STATE_RESPONSE, type)

        var on = false
        var brightness = -1f
        // Proto3 write-side zero-omission (ProtoWriter.float/varint skip a
        // zero value entirely) means a channel at 0 is never on the wire;
        // these defaults double as the decode-side default for "field
        // absent", exactly like a real ESPHome client would see it.
        var red = 0f
        var green = 0f
        var blue = 0f
        var colorMode = -1
        val r = ProtoReader(payload)
        while (r.next()) when (r.field) {
            2 -> on = r.asBool()
            3 -> brightness = r.asFloat()
            4 -> red = r.asFloat()
            5 -> green = r.asFloat()
            6 -> blue = r.asFloat()
            11 -> colorMode = r.asInt()
        }
        assertTrue(on)
        assertEquals(1f, brightness) // pinned to full - see EntityCodec.state
        assertEquals(1f, red)
        assertEquals(128f / 255f, green)
        assertEquals(0f, blue)
        assertEquals(35, colorMode)
    }

    @Test
    fun `light command with rgb decodes to 0-255 r g b`() {
        val w = ProtoWriter()
        w.fixed32(1, 0x1234)
        w.bool(2, true) // has_state
        w.bool(3, true) // state
        w.bool(6, true) // has_rgb
        w.float(7, 1f) // red
        w.float(8, 0.5f) // green
        w.float(9, 0f) // blue
        val command = EntityCodec.parseCommand(Msg.LIGHT_COMMAND_REQUEST, w.toByteArray())
        assertEquals(0x1234, command?.key)
        val value = command?.value as? Map<*, *>
        assertEquals(true, value?.get("on"))
        assertEquals(255, value?.get("r"))
        assertEquals(127, value?.get("g")) // (0.5 * 255).toInt()
        assertEquals(0, value?.get("b"))
    }

    @Test
    fun `light command without rgb carries no colour keys`() {
        val w = ProtoWriter()
        w.fixed32(1, 0x1234)
        w.bool(2, true) // has_state
        w.bool(3, false) // state
        val command = EntityCodec.parseCommand(Msg.LIGHT_COMMAND_REQUEST, w.toByteArray())
        val value = command?.value as? Map<*, *>
        assertEquals(false, value?.get("on"))
        assertNull(value?.get("r"))
    }

    @Test
    fun `rgb led description lists its effects, screen lists none`() {
        val (_, screenPayload) = EntityCodec.describe(screen(), "ks-test")
        val screenEffects = mutableListOf<String>()
        val rScreen = ProtoReader(screenPayload)
        while (rScreen.next()) if (rScreen.field == 11) screenEffects.add(rScreen.asString())
        assertTrue(screenEffects.isEmpty())

        val (_, ledPayload) = EntityCodec.describe(rgbLedWithEffects(), "ks-test")
        val ledEffects = mutableListOf<String>()
        val rLed = ProtoReader(ledPayload)
        while (rLed.next()) if (rLed.field == 11) ledEffects.add(rLed.asString())
        assertEquals(listOf("Pulse", "Strobe", "Random", "Flicker"), ledEffects)
        // "None" is never advertised - HA supplies the clear-effect option itself.
        assertFalse(ledEffects.contains("None"))
    }

    @Test
    fun `rgb led state carries the active effect name`() {
        val (_, payload) = EntityCodec.state(
            rgbLedWithEffects(),
            mapOf("on" to true, "r" to 10, "g" to 20, "b" to 30, "effect" to "Strobe"),
        )!!
        var effect = ""
        val r = ProtoReader(payload)
        while (r.next()) if (r.field == 9) effect = r.asString()
        assertEquals("Strobe", effect)
    }

    @Test
    fun `rgb led state omits the effect field when cleared`() {
        val (_, payload) = EntityCodec.state(
            rgbLedWithEffects(),
            mapOf("on" to true, "r" to 10, "g" to 20, "b" to 30, "effect" to "None"),
        )!!
        var sawEffect = false
        val r = ProtoReader(payload)
        while (r.next()) if (r.field == 9) sawEffect = true
        assertFalse(sawEffect)
    }

    @Test
    fun `light command with has_effect decodes the effect name`() {
        val w = ProtoWriter()
        w.fixed32(1, 0x1234)
        w.bool(18, true) // has_effect
        w.string(19, "Pulse")
        val command = EntityCodec.parseCommand(Msg.LIGHT_COMMAND_REQUEST, w.toByteArray())
        val value = command?.value as? Map<*, *>
        assertEquals("Pulse", value?.get("effect"))
    }

    @Test
    fun `light command without has_effect carries no effect key`() {
        val w = ProtoWriter()
        w.fixed32(1, 0x1234)
        w.bool(2, true) // has_state
        w.bool(3, true) // state
        val command = EntityCodec.parseCommand(Msg.LIGHT_COMMAND_REQUEST, w.toByteArray())
        val value = command?.value as? Map<*, *>
        assertNull(value?.get("effect"))
    }
}
