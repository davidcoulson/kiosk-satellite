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
    fun `a remembered answer survives more strangers than the memo holds`() {
        val f = filter("""{"irks":["$specIrk"]}""")
        assertTrue(f.allows(specRpa, 1, -55, ByteArray(0)))
        // Far more distinct private addresses than are remembered, so the
        // owner's is evicted and has to be resolved from the keys again. The
        // top two bits mark each one resolvable, as they do the spec vector.
        var strangers = 0L
        for (i in 0 until 2000) {
            val address = 0x400000000000L or (i.toLong() shl 8) or 0x5AL
            if (address == specRpa) continue
            if (!f.allows(address, 1, -55, ByteArray(0))) strangers++
        }
        // A 24-bit hash lets about one in sixteen million through by chance.
        assertTrue(strangers >= 1999)
        assertTrue(f.allows(specRpa, 1, -55, ByteArray(0)))
        // Asked twice, a stranger is still a stranger and still counted.
        val before = f.counters()["droppedRpa"] as Long
        assertFalse(f.allows(0x7081940dfbabL, 1, -55, ByteArray(0)))
        assertFalse(f.allows(0x7081940dfbabL, 1, -55, ByteArray(0)))
        assertEquals(before + 2, f.counters()["droppedRpa"])
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
    fun `a named iBeacon rule inherits the threshold unless it sets its own`() {
        // Omitting a limit must not silently be the most permissive setting:
        // a bare rule only exempts the beacon from the manufacturer
        // blocklist and leaves the distance rules where they were.
        val inherits = filter(
            """{"ibeacons":[{"uuidPrefix":"DECAFBAD-FEED-FACE-F00D"}],
                "rssiThreshold":-60,"rssiFloor":-90}"""
        )
        val tag = ibeacon("DECAFBAD-FEED-FACE-F00D-E3AC06854000", 10011, 19641)
        assertTrue(inherits.allows(0xE3AC06854000L, 1, -55, tag))
        assertFalse(inherits.allows(0xE3AC06854000L, 1, -85, tag))

        // Given one, the tracked-tag case works as before: a tag heard
        // weakly here is the reading that places it nearer another proxy, so
        // its own limit is what must be set to keep it.
        val f = filter(
            """{"ibeacons":[{"uuidPrefix":"DECAFBAD-FEED-FACE-F00D","rssi":-90}],
                "rssiThreshold":-60,"rssiFloor":-80}"""
        )
        assertTrue(f.allows(0xE3AC06854000L, 1, -85, tag))
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

    /** An Apple manufacturer-data frame with the given subtype. */
    private fun appleFrame(subtype: Int, payload: ByteArray = ByteArray(4)) =
        byteArrayOf((3 + payload.size).toByte(), 0xFF.toByte(), 0x4C, 0x00, subtype.toByte()) +
            payload

    private fun localName(name: String): ByteArray {
        val bytes = name.toByteArray(Charsets.ISO_8859_1)
        return byteArrayOf((bytes.size + 1).toByte(), 0x09) + bytes
    }

    /** A 16-bit service UUID list (AD type 0x03), little-endian. */
    private fun serviceUuid16(uuid: Int) =
        byteArrayOf(0x03, 0x03, (uuid and 0xFF).toByte(), ((uuid shr 8) and 0xFF).toByte())

    /** A 128-bit service UUID list (AD type 0x07), transmitted reversed. */
    private fun serviceUuid128(uuid: String): ByteArray {
        val bytes = AdvertisementFilter.hexToBytes(uuid.replace("-", ""), 16)!!
        return byteArrayOf(0x11, 0x07) + ByteArray(16) { bytes[15 - it] }
    }

    @Test
    fun `a blocklisted address is dropped ahead of every allow rule`() {
        val f = filter(
            """{"macs":["AA:BB:CC:DD:EE:FF"],"macBlocklist":["AA:BB:CC:DD:EE:FF"]}"""
        )
        // "This panel does not handle this device" is not something a
        // broader allowlist entry may override.
        assertFalse(f.allows(0xAABBCCDDEEFFL, 0, -40, ByteArray(0)))
    }

    @Test
    fun `HomeKit is exempt from an Apple blocklist and Continuity is not`() {
        val f = filter("""{"manufacturers":["0x004C"],"allowHomekit":true}""")
        // HAP accessories carry no IRK, so without this they would be the
        // collateral of a blocklist aimed at AirPods and passing phones.
        assertTrue(f.allows(0x010203040506L, 0, -55, appleFrame(0x06)))
        assertFalse(f.allows(0x010203040506L, 0, -55, appleFrame(0x10)))
    }

    @Test
    fun `FindMy adverts are exempt only when asked, and can carry their own limit`() {
        val airtag = appleFrame(0x12, ByteArray(22))
        val blocked = filter("""{"manufacturers":["0x004C"]}""")
        // Subtype 0x12 from a random static address: no IRK sees it and
        // drop_non_resolvable does not either, so the blocklist is the only
        // thing in its way -- and it takes every one.
        assertFalse(blocked.allows(0x010203040506L, 0, -55, airtag))

        val f = filter(
            """{"manufacturers":["0x004C"],"allowFindmy":{"rssi":-85},
                "rssiThreshold":-70,"rssiFloor":-90}"""
        )
        assertTrue(f.allows(0x010203040506L, 0, -80, airtag))
        // Its own limit overrides the threshold above it and the floor below.
        assertFalse(f.allows(0x010203040506L, 0, -88, airtag))

        // Bare `true` exempts and nothing more: the threshold still applies.
        val bare = filter(
            """{"manufacturers":["0x004C"],"allowFindmy":true,"rssiThreshold":-70}"""
        )
        assertTrue(bare.allows(0x010203040506L, 0, -60, airtag))
        assertFalse(bare.allows(0x010203040506L, 0, -80, airtag))
    }

    @Test
    fun `an allowlisted service UUID carries a device with an unknowable address`() {
        val f = filter(
            """{"serviceUuids":["0xFFF6","00467768-6228-2272-4663-277478268000"],
                "dropNonResolvable":true,"rssiThreshold":-70,"rssiServiceUuid":-90}"""
        )
        val matter = serviceUuid16(0xFFF6)
        // A commissioning device rotates its address and cannot be
        // allowlisted by MAC, so the service UUID is the only handle there
        // is -- and it must survive both the address test and the threshold.
        assertTrue(f.allows(0x001122334455L, 1, -85, matter))
        // Its category limit still bounds it.
        assertFalse(f.allows(0x001122334455L, 1, -95, matter))
        // The 128-bit form is transmitted reversed and still matches.
        assertTrue(f.allows(0x001122334455L, 1, -85, serviceUuid128("00467768-6228-2272-4663-277478268000")))
        // Anything else at that strength is still taken by the threshold.
        assertFalse(f.allows(0x001122334455L, 1, -85, ByteArray(0)))
    }

    @Test
    fun `a short advertised in its long base form still matches a 16-bit entry`() {
        val f = filter("""{"serviceUuids":["0xFEED"],"allowlistExclusive":true}""")
        assertTrue(f.allows(0x1L, 1, -50, serviceUuid128("0000FEED-0000-1000-8000-00805F9B34FB")))
        assertFalse(f.allows(0x1L, 1, -50, serviceUuid128("0000FEEC-0000-1000-8000-00805F9B34FB")))
    }

    @Test
    fun `per-category limits are independent of one another`() {
        // Categorising before measuring is what buys this: a category can be
        // looser OR stricter than the fleet threshold, where a filter that
        // measured first could only ever tighten.
        val f = filter(
            """{"irks":["$specIrk"],"macs":["AA:BB:CC:DD:EE:FF"],
                "rssiThreshold":-70,"rssiFloor":-95,"rssiIrk":-90,"rssiMacAllowlist":-80}"""
        )
        // IRK gets more range than the threshold.
        assertTrue(f.allows(specRpa, 1, -85, ByteArray(0)))
        assertFalse(f.allows(specRpa, 1, -92, ByteArray(0)))
        // The allowlist gets less than the floor would have given it.
        assertTrue(f.allows(0xAABBCCDDEEFFL, 0, -75, ByteArray(0)))
        assertFalse(f.allows(0xAABBCCDDEEFFL, 0, -85, ByteArray(0)))
    }

    @Test
    fun `an iBeacon rule with its own limit overrides the floor`() {
        // The calibration-beacon case: the weak cross-room pairs are the
        // ones carrying the geometry, so the floor must not take them.
        val f = filter(
            """{"ibeacons":[{"uuidPrefix":"decafbad","major":1,"rssi":-95}],
                "manufacturers":["0x004C"],"rssiThreshold":-70,"rssiFloor":-90}"""
        )
        val probe = ibeacon("DECAFBAD-FEED-FACE-F00D-E3AC06854000", 1, 1)
        assertTrue(f.allows(0x4C11AE123456L, 0, -93, probe))
        assertFalse(f.allows(0x4C11AE123456L, 0, -97, probe))
    }

    @Test
    fun `a blocklisted local name is dropped and a protected device is not`() {
        val f = filter("""{"names":["airpods"],"macs":["AA:BB:CC:DD:EE:FF"]}""")
        assertFalse(f.allows(0x010203040506L, 0, -55, localName("David's AirPods Pro")))
        assertTrue(f.allows(0xAABBCCDDEEFFL, 0, -55, localName("David's AirPods Pro")))
    }

    @Test
    fun `a truncated advertisement is walked safely`() {
        val f = filter("""{"manufacturers":["0x004C"],"names":["x"],"serviceUuids":["0xFFF6"]}""")
        // A field claiming more bytes than the packet holds must end the
        // walk rather than read off the end of it.
        assertTrue(f.allows(0x1L, 0, -50, byteArrayOf(0x1F, 0xFF.toByte(), 0x4C)))
    }

    @Test
    fun `a rule with no UUID admits every iBeacon at one limit`() {
        // The component's bare `allow_ibeacon: true`, which exists because
        // subtype 0x02 is Apple manufacturer data and an Apple blocklist
        // would otherwise take every beacon in the house with it.
        val f = filter(
            """{"ibeacons":[{"rssi":-90}],"manufacturers":["0x004C"],"rssiThreshold":-60}"""
        )
        assertTrue(f.allows(0x1L, 1, -85, ibeacon("FDA50693-A4E2-4FB1-AFCF-C6EB07647825", 1, 2)))
        assertFalse(f.allows(0x1L, 1, -95, ibeacon("FDA50693-A4E2-4FB1-AFCF-C6EB07647825", 1, 2)))
    }
}
