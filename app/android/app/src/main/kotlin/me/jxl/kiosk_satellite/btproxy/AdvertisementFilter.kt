package me.jxl.kiosk_satellite.btproxy

import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

/**
 * Decides which BLE advertisements a panel relays to Home Assistant.
 *
 * Modelled on the author's esphome-bluetooth-proxy-filter, which solves the
 * same problem on an ESP32: core ESPHome forwards every packet it receives,
 * and so does this proxy. On a wall panel the volume is the point -- one
 * here relayed 109 devices while holding zero connections -- and most of it
 * is devices the house cannot track: other people's phones and watches,
 * rotating private addresses, AirPods and AirTags.
 *
 * <h2>Order, and why categorise before measuring</h2>
 *
 * 1. Below [rssiFloor] -> drop. Global, applies to allowlisted devices too.
 * 2. Categorise, cheapest test first: allowlisted address -> MAC; a
 *    resolvable private address resolving to one of [irks] -> IRK (an RPA
 *    resolving to none is dropped); anything else -> DEFAULT.
 * 3. Below that category's limit -> drop.
 * 4. [allowlistExclusive] and DEFAULT -> drop.
 * 5. Non-resolvable private address, with [dropNonResolvable], unprotected
 *    -> drop.
 * 6. Blocklisted manufacturer id, unprotected -> drop.
 * 7. Otherwise forward.
 *
 * MAC and IRK hits mark the advertisement *protected*, which is what makes a
 * `manufacturer_blocklist` of Apple usable at all: your own phones and
 * watches advertise Apple manufacturer data, so without the flag the
 * blocklist would discard exactly the devices the IRK list exists to keep.
 *
 * <h2>What is deliberately not here</h2>
 *
 * The ESPHome component also carries per-category RSSI limits, a service
 * UUID allowlist, iBeacon major/minor exemptions, HomeKit subtype
 * exemptions and a local-name blocklist. Those earn their place on a
 * house's primary proxy, which must keep commissioning beacons and
 * calibration probes alive. A panel is not that proxy -- it is the one
 * thing that can say someone is standing in front of it -- so this carries
 * the parts that serve that and says plainly that it carries no more.
 */
/** One iBeacon allowlist rule: a UUID prefix and optional major/minor. */
internal data class IBeaconRule(
    /** Hex, dashes stripped, matched as a prefix so a family of tags that
     *  share a namespace needs one rule rather than one per animal. */
    val uuidPrefix: String,
    val major: Int?,
    val minor: Int?,
) {
    fun matches(uuidHex: String, major: Int, minor: Int): Boolean =
        uuidHex.startsWith(uuidPrefix) &&
            (this.major == null || this.major == major) &&
            (this.minor == null || this.minor == minor)
}

internal class AdvertisementFilter private constructor(
    private val irks: List<ByteArray>,
    private val ibeacons: List<IBeaconRule>,
    private val macAllowlist: Set<Long>,
    private val manufacturerBlocklist: Set<Int>,
    private val dropNonResolvable: Boolean,
    private val allowlistExclusive: Boolean,
    private val rssiFloor: Int,
    private val rssiThreshold: Int,
) {
    /** Counters, so the effect is measurable per panel rather than guessed. */
    @Volatile var forwarded: Long = 0L; private set
    @Volatile var dropped: Long = 0L; private set
    @Volatile var droppedRpa: Long = 0L; private set

    val active: Boolean
        get() = irks.isNotEmpty() || macAllowlist.isNotEmpty() ||
            manufacturerBlocklist.isNotEmpty() || dropNonResolvable ||
            allowlistExclusive || rssiFloor != 0 || rssiThreshold != 0 ||
            ibeacons.isNotEmpty()

    fun counters(): Map<String, Any> = mapOf(
        "forwarded" to forwarded,
        "dropped" to dropped,
        "droppedRpa" to droppedRpa,
        "irks" to irks.size,
        "macAllowlist" to macAllowlist.size,
    )

    /**
     * [address] is the six address bytes as a long, big-endian, the same
     * packing [BleAdvertisement] uses. [payload] is the raw advertising
     * data, already length-checked by the caller.
     */
    fun allows(address: Long, addressType: Int, rssi: Int, payload: ByteArray): Boolean {
        val verdict = decide(address, addressType, rssi, payload)
        if (verdict) forwarded++ else dropped++
        return verdict
    }

    private fun decide(address: Long, addressType: Int, rssi: Int, payload: ByteArray): Boolean {
        if (rssiFloor != 0 && rssi < rssiFloor) return false

        // Cheapest first: a set lookup, then AES only for actual RPAs.
        val allowlisted = macAllowlist.contains(address)
        var protectedAdv = allowlisted
        // An iBeacon the owner named is protected like an allowlisted
        // address, and for the same reason: a tracked tag heard weakly here
        // is the measurement that places it nearer another proxy, so the
        // threshold must not take it. The floor above still bounds it.
        if (!protectedAdv && ibeacons.isNotEmpty() && matchesIbeacon(payload)) {
            protectedAdv = true
        }
        if (!allowlisted && irks.isNotEmpty() && isResolvable(address, addressType)) {
            if (!irkMatches(address)) {
                droppedRpa++
                return false
            }
            protectedAdv = true
        }

        // The allowlist bypasses the threshold on purpose: a weak reading at
        // this panel is exactly what places a tag nearer another proxy, so
        // dropping it removes the measurement that does the placing. The
        // floor above still bounds it.
        if (!protectedAdv && rssiThreshold != 0 && rssi < rssiThreshold) return false
        if (allowlistExclusive && !protectedAdv) return false
        if (dropNonResolvable && !protectedAdv && isNonResolvable(address, addressType)) return false
        if (!protectedAdv && manufacturerBlocklist.isNotEmpty() &&
            payloadCarriesBlockedManufacturer(payload)
        ) {
            return false
        }
        return true
    }

    /**
     * iBeacon is Apple manufacturer data (company 0x004C) with subtype 0x02
     * and length 0x15, carrying a 16-byte UUID then big-endian major and
     * minor. Parsed here rather than trusted from a name, since the name is
     * the one field a beacon need not carry.
     */
    private fun matchesIbeacon(payload: ByteArray): Boolean {
        var index = 0
        while (index + 1 < payload.size) {
            val len = payload[index].toInt() and 0xFF
            if (len == 0) return false
            val type = payload[index + 1].toInt() and 0xFF
            // 0xFF, 004C, 02, 15, 16-byte uuid, major, minor = 25 bytes of
            // data after the length byte.
            if (type == 0xFF && len >= 25 && index + 25 < payload.size &&
                (payload[index + 2].toInt() and 0xFF) == 0x4C &&
                (payload[index + 3].toInt() and 0xFF) == 0x00 &&
                (payload[index + 4].toInt() and 0xFF) == 0x02 &&
                (payload[index + 5].toInt() and 0xFF) == 0x15
            ) {
                val uuid = StringBuilder(32)
                for (i in 0 until 16) {
                    uuid.append("%02x".format(payload[index + 6 + i].toInt() and 0xFF))
                }
                val major = ((payload[index + 22].toInt() and 0xFF) shl 8) or
                    (payload[index + 23].toInt() and 0xFF)
                val minor = ((payload[index + 24].toInt() and 0xFF) shl 8) or
                    (payload[index + 25].toInt() and 0xFF)
                val hex = uuid.toString()
                for (rule in ibeacons) if (rule.matches(hex, major, minor)) return true
            }
            index += 1 + len
        }
        return false
    }

    /** Manufacturer data is AD type 0xFF, company id little-endian first. */
    private fun payloadCarriesBlockedManufacturer(payload: ByteArray): Boolean {
        var index = 0
        while (index + 1 < payload.size) {
            val len = payload[index].toInt() and 0xFF
            if (len == 0) return false
            val type = payload[index + 1].toInt() and 0xFF
            if (type == 0xFF && len >= 3 && index + 3 < payload.size) {
                val company = (payload[index + 2].toInt() and 0xFF) or
                    ((payload[index + 3].toInt() and 0xFF) shl 8)
                if (manufacturerBlocklist.contains(company)) return true
            }
            index += 1 + len
        }
        return false
    }

    /**
     * Bluetooth Core "ah": hash = e(IRK, 0-padding | prand) truncated to 24
     * bits, where an RPA is prand (top three bytes) followed by hash (bottom
     * three).
     */
    private fun irkMatches(address: Long): Boolean {
        val plaintext = ByteArray(16)
        plaintext[13] = ((address shr 40) and 0xFF).toByte()
        plaintext[14] = ((address shr 32) and 0xFF).toByte()
        plaintext[15] = ((address shr 24) and 0xFF).toByte()
        for (irk in irks) {
            val out = try {
                aes(irk, plaintext)
            } catch (_: Throwable) {
                return false
            }
            if ((out[15].toInt() and 0xFF) == (address and 0xFF).toInt() &&
                (out[14].toInt() and 0xFF) == ((address shr 8) and 0xFF).toInt() &&
                (out[13].toInt() and 0xFF) == ((address shr 16) and 0xFF).toInt()
            ) {
                return true
            }
        }
        return false
    }

    private fun aes(key: ByteArray, block: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/ECB/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
        return cipher.doFinal(block)
    }

    companion object {
        /**
         * Both address-class tests are guarded on the address type as well
         * as the leading bits, which is load-bearing: real public OUIs exist
         * in both bit ranges (Espressif's 4C: in the resolvable range, 00:
         * and 04: in the non-resolvable one), and matching on bits alone
         * would misclassify them.
         */
        fun isResolvable(address: Long, addressType: Int): Boolean =
            addressType != 0 && ((address shr 40) and 0xC0L) == 0x40L

        fun isNonResolvable(address: Long, addressType: Int): Boolean =
            addressType != 0 && ((address shr 40) and 0xC0L) == 0x00L

        /** An empty or unparseable configuration filters nothing. */
        fun parse(json: String?): AdvertisementFilter? {
            if (json.isNullOrBlank()) return null
            val root = try {
                JSONObject(json)
            } catch (_: Throwable) {
                return null
            }
            val irks = mutableListOf<ByteArray>()
            root.optJSONArray("irks")?.let { array ->
                for (i in 0 until array.length()) {
                    hexToBytes(array.optString(i), 16)?.let(irks::add)
                }
            }
            val macs = mutableSetOf<Long>()
            root.optJSONArray("macs")?.let { array ->
                for (i in 0 until array.length()) {
                    macToLong(array.optString(i))?.let(macs::add)
                }
            }
            val manufacturers = mutableSetOf<Int>()
            root.optJSONArray("manufacturers")?.let { array ->
                for (i in 0 until array.length()) {
                    val raw = array.opt(i)
                    val value = when (raw) {
                        is Number -> raw.toInt()
                        is String -> raw.trim().removePrefix("0x").removePrefix("0X")
                            .toIntOrNull(16)
                        else -> null
                    }
                    if (value != null && value in 0..0xFFFF) manufacturers.add(value)
                }
            }
            val ibeacons = mutableListOf<IBeaconRule>()
            root.optJSONArray("ibeacons")?.let { array ->
                for (i in 0 until array.length()) {
                    val rule = array.optJSONObject(i) ?: continue
                    val prefix = rule.optString("uuidPrefix")
                        .replace("-", "").replace(":", "").lowercase()
                    if (prefix.isEmpty()) continue
                    ibeacons.add(
                        IBeaconRule(
                            uuidPrefix = prefix,
                            major = if (rule.has("major")) rule.optInt("major") else null,
                            minor = if (rule.has("minor")) rule.optInt("minor") else null,
                        )
                    )
                }
            }
            val filter = AdvertisementFilter(
                irks = irks,
                ibeacons = ibeacons,
                macAllowlist = macs,
                manufacturerBlocklist = manufacturers,
                dropNonResolvable = root.optBoolean("dropNonResolvable", false),
                allowlistExclusive = root.optBoolean("allowlistExclusive", false),
                rssiFloor = root.optInt("rssiFloor", 0),
                rssiThreshold = root.optInt("rssiThreshold", 0),
            )
            return if (filter.active) filter else null
        }

        fun hexToBytes(text: String?, expected: Int): ByteArray? {
            val clean = text?.trim()?.replace(":", "")?.replace(" ", "") ?: return null
            if (clean.length != expected * 2) return null
            val out = ByteArray(expected)
            for (i in 0 until expected) {
                val byte = clean.substring(i * 2, i * 2 + 2).toIntOrNull(16) ?: return null
                out[i] = byte.toByte()
            }
            return out
        }

        /** "AA:BB:CC:DD:EE:FF" to the same packing the scanner uses. */
        fun macToLong(text: String?): Long? =
            text?.trim()?.replace(":", "")?.replace("-", "")
                ?.takeIf { it.length == 12 }
                ?.toLongOrNull(16)
    }
}
