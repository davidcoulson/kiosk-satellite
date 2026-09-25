package me.jxl.kiosk_satellite.btproxy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The event entity (the Remote key event): described with its event
 *  types, fired only by a live push, and never replayed to a client that
 *  subscribes later. */
class EventEntityTest {
    private val event = EspEntity.fromMap(
        mapOf(
            "type" to "event", "objectId" to "remote_key", "name" to "Remote key",
            "icon" to "mdi:remote", "deviceClass" to "button",
            "eventTypes" to listOf("home", "back", "dpad_up"),
        ),
    ) as EspEntity.Event

    @Test
    fun `the description lists every event type`() {
        val (type, payload) = EntityCodec.describe(event, "ks")
        assertEquals(Msg.LIST_ENTITIES_EVENT_RESPONSE, type)
        val types = mutableListOf<String>()
        var deviceClass = ""
        ProtoReader(payload).let { r ->
            while (r.next()) when (r.field) {
                8 -> deviceClass = r.asString()
                9 -> types.add(r.asString())
            }
        }
        assertEquals(listOf("home", "back", "dpad_up"), types)
        assertEquals("button", deviceClass)
    }

    @Test
    fun `a push fires the event with its type`() {
        val (type, payload) = EntityCodec.state(event, "back")!!
        assertEquals(Msg.EVENT_RESPONSE, type)
        var key = 0
        var fired = ""
        ProtoReader(payload).let { r ->
            while (r.next()) when (r.field) {
                1 -> key = r.asFixed32()
                2 -> fired = r.asString()
            }
        }
        assertEquals(event.key, key)
        assertEquals("back", fired)
    }

    @Test
    fun `there is no state to send on subscribe`() {
        assertNull(EntityCodec.state(event, null))
    }

    @Test
    fun `a fired event is not cached for the next client`() {
        val hub = EntityHub(listOf(event), onCommand = { _, _ -> })
        hub.updateState("remote_key", "home")
        assertNull(hub.valueOf(event))
    }
}
