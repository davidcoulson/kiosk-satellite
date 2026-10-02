package me.jxl.kiosk_satellite.btproxy

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Keys from Home Assistant, with the ESP proxies' irks-from-ha.yaml
 * semantics: what counts as a key, what is ignored, what clears, and which
 * list the filter ends up using.
 */
class HomeAssistantIrksTest {
    private val a = "00112233445566778899aabbccddeeff"
    private val b = "FFEEDDCCBBAA99887766554433221100"

    /** The Bluetooth Core worked example: this key resolves [specRpa]. */
    private val specIrk = "ec0234a357c8ad05341010a60a397d9b"
    private val specRpa = 0x7081940dfbaaL

    private class MemoryStore(var saved: String = "") : HomeAssistantIrks.Store {
        var writes = 0
        override fun load(): String = saved
        override fun save(keys: String) {
            saved = keys
            writes++
        }
    }

    private fun hex(key: ByteArray) = key.joinToString("") { "%02x".format(it) }

    private fun filter(json: String) = AdvertisementFilter.parse(json)!!

    @Test
    fun `keys are found beside names, in either case, and a longer run is not cut`() {
        val keys = HomeAssistantIrks.extract(
            "David phone: $a\nDavid watch: $b\nhash: ${a}${b}\n$a again"
        )!!
        // Two keys: the 64-digit run is something else, and the repeat of
        // the first is the same key.
        assertEquals(listOf(a, b.lowercase()), keys.map(::hex))
        // A Python list repr, which is how Home Assistant sends a list attribute.
        assertEquals(2, HomeAssistantIrks.extract("['$a', '$b']")!!.size)
        // 31 and 33 digits are not keys either.
        assertNull(HomeAssistantIrks.extract(a.drop(1)))
        assertNull(HomeAssistantIrks.extract(a + "0"))
    }

    @Test
    fun `the key count is bounded`() {
        val many = (0 until 20).joinToString(" ") { "%032x".format(it + 1) }
        assertEquals(HomeAssistantIrks.MAX_KEYS, HomeAssistantIrks.extract(many)!!.size)
    }

    @Test
    fun `a value with no key keeps the current list`() {
        val f = filter("""{"irksEntity":"sensor.ble_proxy_irks","irksAttribute":"irks"}""")
        val store = MemoryStore()
        val irks = HomeAssistantIrks(f, store, log = {})
        irks.onState("sensor.ble_proxy_irks", "irks", "phone: $specIrk")
        assertEquals("home_assistant", f.counters()["irksSource"])
        for (value in listOf("unavailable", "unknown", "", "  ")) {
            irks.onState("sensor.ble_proxy_irks", "irks", value)
        }
        assertEquals(1, f.counters()["irks"])
        assertEquals(specIrk, store.saved)
        assertEquals(1, store.writes)
        assertTrue(f.allows(specRpa, 1, -55, ByteArray(0)))
    }

    @Test
    fun `clear empties the list and falls back to the setting's keys`() {
        val f = filter("""{"irks":["$a"],"irksEntity":"sensor.k"}""")
        val store = MemoryStore()
        val irks = HomeAssistantIrks(f, store, log = {})
        irks.onState("sensor.k", "", "$specIrk $b")
        assertEquals(2, f.counters()["irks"])
        assertEquals("home_assistant", f.counters()["irksSource"])

        irks.onState("sensor.k", "", "  Clear ")
        assertEquals(1, f.counters()["irks"])
        assertEquals("setting", f.counters()["irksSource"])
        assertEquals("", store.saved)
        assertFalse(f.allows(specRpa, 1, -55, ByteArray(0)))
    }

    @Test
    fun `only the configured entity and attribute are listened to`() {
        val f = filter("""{"irksEntity":"sensor.k","irksAttribute":"irks"}""")
        val irks = HomeAssistantIrks(f, MemoryStore(), log = {})
        assertEquals(listOf("sensor.k" to "irks"), irks.subscriptions)
        irks.onState("sensor.other", "irks", specIrk)
        irks.onState("sensor.k", "", specIrk)
        assertEquals("none", f.counters()["irksSource"])
    }

    @Test
    fun `the last delivered list is used from boot`() {
        val store = MemoryStore("$specIrk,$a")
        val f = filter("""{"irks":["$b"],"irksEntity":"sensor.k"}""")
        HomeAssistantIrks(f, store, log = {})
        assertEquals("home_assistant", f.counters()["irksSource"])
        assertEquals(2, f.counters()["irks"])
        assertTrue(f.allows(specRpa, 1, -55, ByteArray(0)))
    }

    @Test
    fun `an unchanged resend is not written or logged again, and no key is logged`() {
        val lines = mutableListOf<String>()
        val store = MemoryStore()
        val f = filter("""{"irksEntity":"sensor.k"}""")
        val irks = HomeAssistantIrks(f, store, log = { lines.add(it) })
        irks.onState("sensor.k", "", "phone: $specIrk")
        irks.onState("sensor.k", "", "renamed: ${specIrk.uppercase()}")
        assertEquals(1, store.writes)
        assertEquals(1, lines.size)
        assertTrue(lines.none { it.contains(specIrk, ignoreCase = true) })
    }

    @Test
    fun `subscribe and state messages round-trip with api dot proto's field numbers`() {
        val subscribe = ApiCodec.subscribeHomeAssistantState("sensor.ble_proxy_irks", "irks")
        var entity = ""
        var attribute = ""
        var once: Boolean? = null
        ProtoReader(subscribe).let { r ->
            while (r.next()) when (r.field) {
                1 -> entity = r.asString()
                2 -> attribute = r.asString()
                3 -> once = r.asBool()
            }
        }
        assertEquals("sensor.ble_proxy_irks", entity)
        assertEquals("irks", attribute)
        // once=false: every change, not just the first value. Proto3 leaves
        // a false bool off the wire entirely.
        assertNull(once)
        ProtoReader(ApiCodec.subscribeHomeAssistantState("sensor.k", "", once = true)).let { r ->
            while (r.next()) if (r.field == 3) once = r.asBool()
        }
        assertEquals(true, once)

        val state = ProtoWriter().run {
            string(1, "sensor.ble_proxy_irks")
            string(2, "phone: $a")
            string(3, "irks")
            toByteArray()
        }
        val parsed = ApiCodec.parseHomeAssistantState(state)
        assertEquals("sensor.ble_proxy_irks", parsed.entityId)
        assertEquals("phone: $a", parsed.state)
        assertEquals("irks", parsed.attribute)
        assertEquals(39, Msg.SUBSCRIBE_HOME_ASSISTANT_STATE_RESPONSE)
        assertEquals(40, Msg.HOME_ASSISTANT_STATE_RESPONSE)
    }
}
