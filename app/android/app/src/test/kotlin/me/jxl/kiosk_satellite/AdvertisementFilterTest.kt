package me.jxl.kiosk_satellite

import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import me.jxl.kiosk_satellite.btproxy.AdvertisementFilter
import org.junit.Test

/**
 * The filter decides what a panel tells Home Assistant about, so its
 * mistakes are invisible: a wrong drop looks like a device that is simply
 * not there, and a wrong keep looks like nothing at all.
 *
 * The resolution vector is the Bluetooth Core specification's own worked
 * example for `ah`, not a value produced by this code -- a self-generated
 * expectation would pass just as happily with the prand and hash halves
 * swapped, which is the mistake this is guarding.
 */
class AdvertisementFilterTest {
    private val specIrk = "ec0234a357c8ad05341010a60a397d9b"

    /** prand 708194 | hash 0dfbaa, from the same worked example. */
    private val specRpa = 0x7081940dfbaaL

    private fun filter(json: String) = AdvertisementFilter.parse(json)!!

    @Test
    fun `an RPA resolving to a listed IRK is forwarded`() {
        val f = filter("""{"irks":["$specIrk"]}""")
        assertTrue(f.allows(specRpa, 1, -55, ByteArray(0)))
    }

    @Test
    fun `an RPA resolving to no listed IRK is dropped as somebody else's`() {
        val f = filter("""{"irks":["$specIrk"]}""")
        // Same prand, one bit different in the hash: a real resolution has to
        // fail here, where a truncation or byte-order slip would still match.
        assertFalse(f.allows(0x7081940dfbabL, 1, -55, ByteArray(0)))
        assertEquals(1L, f.counters()["droppedRpa"])
    }

    @Test
    fun `a public address is never treated as resolvable`() {
        // Espressif's 4C: OUI sits inside the RPA bit range, so matching on
        // bits alone would send every ESP32 through the IRK test and drop it.
        val espressif = 0x4C11AE1234L
        assertFalse(AdvertisementFilter.isResolvable(espressif, 0))
        val f = filter("""{"irks":["$specIrk"]}""")
        assertTrue(f.allows(espressif, 0, -55, ByteArray(0)))
    }

    @Test
    fun `a non-resolvable private address is dropped when asked`() {
        val nonResolvable = 0x001122334455L
        assertTrue(AdvertisementFilter.isNonResolvable(nonResolvable, 1))
        assertFalse(AdvertisementFilter.isNonResolvable(nonResolvable, 0))
        val f = filter("""{"dropNonResolvable":true}""")
        assertFalse(f.allows(nonResolvable, 1, -55, ByteArray(0)))
        assertTrue(f.allows(nonResolvable, 0, -55, ByteArray(0)))
    }

    @Test
    fun `an allowlisted address bypasses the threshold but not the floor`() {
        val f = filter(
            """{"macs":["AA:BB:CC:DD:EE:FF"],"rssiThreshold":-70,"rssiFloor":-90}"""
        )
        val tag = 0xAABBCCDDEEFFL
        // A weak reading here is what places the tag nearer another proxy,
        // so the threshold must not take it.
        assertTrue(f.allows(tag, 0, -85, ByteArray(0)))
        // The floor still bounds it: below this an RSSI carries no usable
        // distance and misleads a tracker rather than helping it.
        assertFalse(f.allows(tag, 0, -95, ByteArray(0)))
        // Anything unprotected still pays the threshold.
        assertFalse(f.allows(0x010203040506L, 0, -85, ByteArray(0)))
    }

    @Test
    fun `an IRK match protects a device from the manufacturer blocklist`() {
        // Apple manufacturer data: length, AD type 0xFF, company 0x004C LE.
        val apple = byteArrayOf(0x03, 0xFF.toByte(), 0x4C, 0x00)
        val f = filter("""{"irks":["$specIrk"],"manufacturers":["0x004C"]}""")
        // Your own phone advertises Apple data too, so without the protected
        // flag the blocklist would discard exactly what the IRK list keeps.
        assertTrue(f.allows(specRpa, 1, -55, apple))
        // A fixed-address Apple device has no IRK to rescue it.
        assertFalse(f.allows(0x010203040506L, 0, -55, apple))
    }

    @Test
    fun `exclusive mode keeps only what is matched`() {
        val f = filter("""{"macs":["AA:BB:CC:DD:EE:FF"],"allowlistExclusive":true}""")
        assertTrue(f.allows(0xAABBCCDDEEFFL, 0, -55, ByteArray(0)))
        assertFalse(f.allows(0x010203040506L, 0, -55, ByteArray(0)))
    }

    @Test
    fun `an empty or broken configuration filters nothing`() {
        assertEquals(null, AdvertisementFilter.parse(null))
        assertEquals(null, AdvertisementFilter.parse(""))
        assertEquals(null, AdvertisementFilter.parse("{}"))
        assertEquals(null, AdvertisementFilter.parse("not json"))
        // A key that parses to nothing usable must not become a filter that
        // drops everything.
        assertEquals(null, AdvertisementFilter.parse("""{"irks":["too-short"]}"""))
    }

    @Test
    fun `counters report what was forwarded and dropped`() {
        val f = filter("""{"rssiThreshold":-70}""")
        f.allows(0x010203040506L, 0, -60, ByteArray(0))
        f.allows(0x010203040506L, 0, -80, ByteArray(0))
        assertEquals(1L, f.counters()["forwarded"])
        assertEquals(1L, f.counters()["dropped"])
    }

    /** A real iBeacon frame: AD length, 0xFF, company 004C LE, subtype 02,
     *  length 15, 16-byte UUID, major and minor big-endian, tx power. */
    private fun ibeacon(uuidHex: String, major: Int, minor: Int): ByteArray {
        val uuid = AdvertisementFilter.hexToBytes(uuidHex.replace("-", ""), 16)!!
        return byteArrayOf(0x1A, 0xFF.toByte(), 0x4C, 0x00, 0x02, 0x15) + uuid +
            byteArrayOf(
                ((major shr 8) and 0xFF).toByte(), (major and 0xFF).toByte(),
                ((minor shr 8) and 0xFF).toByte(), (minor and 0xFF).toByte(),
                0xC5.toByte(),
            )
    }

    @Test
    fun `a named iBeacon is protected from the threshold like an allowlisted tag`() {
        // The tracked-pet case: a tag heard weakly here is the reading that
        // places it nearer another proxy, so the threshold must not take it.
        val f = filter(
            """{"ibeacons":[{"uuidPrefix":"DECAFBAD-FEED-FACE-F00D"}],
                "rssiThreshold":-60,"rssiFloor":-90}"""
        )
        val tag = ibeacon("DECAFBAD-FEED-FACE-F00D-E3AC06854000", 10011, 19641)
        assertTrue(f.allows(0xE3AC06854000L, 1, -85, tag))
        // The floor still bounds it.
        assertFalse(f.allows(0xE3AC06854000L, 1, -95, tag))
        // A different namespace gets no protection and pays the threshold.
        val other = ibeacon("FDA50693-A4E2-4FB1-AFCF-C6EB07647825", 10011, 19641)
        assertFalse(f.allows(0xC6EB07647825L, 1, -85, other))
    }

    @Test
    fun `major and minor narrow an iBeacon rule when given`() {
        val f = filter(
            """{"ibeacons":[{"uuidPrefix":"DECAFBAD-FEED-FACE-F00D","major":10011,"minor":19641}],
                "allowlistExclusive":true}"""
        )
        assertTrue(f.allows(0x1L, 1, -50, ibeacon("DECAFBAD-FEED-FACE-F00D-E3AC06854000", 10011, 19641)))
        assertFalse(f.allows(0x1L, 1, -50, ibeacon("DECAFBAD-FEED-FACE-F00D-E3AC06854000", 10011, 1)))
        assertFalse(f.allows(0x1L, 1, -50, ibeacon("DECAFBAD-FEED-FACE-F00D-E3AC06854000", 1, 19641)))
    }

    @Test
    fun `a non-iBeacon Apple frame is not mistaken for one`() {
        // Continuity, HomeKit and the rest share company 0x004C; only
        // subtype 0x02 with length 0x15 is an iBeacon.
        val f = filter("""{"ibeacons":[{"uuidPrefix":"decafbad"}],"allowlistExclusive":true}""")
        val continuity = byteArrayOf(0x0B, 0xFF.toByte(), 0x4C, 0x00, 0x10, 0x06) +
            ByteArray(8) { 0xDE.toByte() }
        assertFalse(f.allows(0x1L, 1, -50, continuity))
    }
}
