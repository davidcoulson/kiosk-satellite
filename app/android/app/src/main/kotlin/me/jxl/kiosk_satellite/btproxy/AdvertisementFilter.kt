package me.jxl.kiosk_satellite.btproxy

import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject

/**
 * Decides which BLE advertisements a panel relays to Home Assistant.
 *
 * A port of the author's esphome-bluetooth-proxy-filter, which solves the
 * same problem on an ESP32: core ESPHome forwards every packet it receives,
 * and so does this proxy. On a wall panel the volume is the point -- one
 * here relayed 109 devices while holding zero connections -- and most of it
 * is devices the house cannot track: other people's phones and watches,
 * rotating private addresses, AirPods and AirTags.
 *
 * The chain below is the ESPHome component's, in its order and with its
 * names, so a filter written for the proxies can be pasted onto a panel and
 * behave the same way. The one deliberate difference is spelling: this
 * takes JSON with camelCase keys rather than YAML, and an unset RSSI limit
 * is `0` here where the component uses `-127`.
 *
 * <h2>Order, and why categorise before measuring</h2>
 *
 * 1. On [macBlocklist] -> drop, ahead of every allow rule. "This proxy does
 *    not handle this device" is not something a broader allowlist may
 *    override.
 * 2. Below [preGate] -> drop. The loosest limit any category could apply,
 *    computed once at parse. Cheapest test there is, so the bulk of distant
 *    noise never reaches the categoriser.
 * 3. Categorise, cheapest test first, first hit wins: allowlisted address ->
 *    MAC; a resolvable private address resolving to one of [irks] -> IRK (an
 *    RPA resolving to none is dropped outright); a matching iBeacon rule ->
 *    IBEACON; Apple FindMy manufacturer data -> FINDMY; an allowlisted
 *    service UUID in the payload -> UUID; anything else -> DEFAULT.
 * 4. Below that category's own RSSI limit -> drop.
 * 5. [allowlistExclusive] and DEFAULT -> drop.
 * 6. Non-resolvable private address, with [dropNonResolvable], unprotected
 *    -> drop.
 * 7. Blocklisted manufacturer id or local name, unprotected -> drop.
 * 8. Otherwise forward.
 *
 * Every category except DEFAULT marks the advertisement *protected*, which
 * is what makes a `manufacturers` list containing Apple usable at all: your
 * own phones and watches advertise Apple manufacturer data, so without the
 * flag the blocklist would discard exactly the devices the IRK list exists
 * to keep.
 *
 * <h2>Inheriting, and what an unset limit means</h2>
 *
 * Categorising before measuring is what makes the four limits independent:
 * any category can be looser *or* stricter than any other. An unset (`0`)
 * limit inherits, and what it inherits from reproduces the behaviour of a
 * filter that sets nothing:
 *
 *  - MAC -> no further limit; bounded only by [rssiFloor]. The allowlist has
 *    always been a full bypass of the threshold, because a weak reading here
 *    is exactly what places a tag nearer another proxy.
 *  - IRK, UUID, DEFAULT -> [rssiThreshold].
 *  - IBEACON, FINDMY -> [rssiThreshold], and the floor still applies. A rule
 *    that carries its own `rssi` overrides both, which is what lets a
 *    house's own calibration beacons through at any strength while tracked
 *    tags stay bounded.
 *
 * <h2>What is deliberately not here</h2>
 *
 * `allow_espressif`, which exempts Espressif OUIs from the IRK test. It is
 * near-inert on the ESP side (ESPHome advertises from the public MAC, and a
 * public address is never an RPA, so [isResolvable]'s address-type guard
 * already covers it) and would only matter for an ESP advertising with a
 * random address. Everything else the component filters on is here.
 */
/** One iBeacon allowlist rule: a UUID prefix, optional major/minor, and an
 *  optional RSSI limit of its own (0 inherits). */
internal data class IBeaconRule(
    /** Hex, dashes stripped, matched as a prefix so a family of tags that
     *  share a namespace needs one rule rather than one per animal. Empty
     *  matches any iBeacon, which is the component's bare `allow_ibeacon:
     *  true` -- useful with an `rssi` to admit every beacon at one limit. */
    val uuidPrefix: String,
    val major: Int?,
    val minor: Int?,
    /** dBm, or 0 to inherit the threshold. A value here overrides the floor
     *  as well, so a beacon the house owns can be forwarded at any strength. */
    val rssi: Int = 0,
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
    private val macBlocklist: Set<Long>,
    private val manufacturerBlocklist: Set<Int>,
    private val nameBlocklist: List<String>,
    private val serviceUuids16: Set<Int>,
    private val serviceUuids128: List<ByteArray>,
    private val allowHomekit: Boolean,
    private val allowFindmy: Boolean,
    private val findmyRssi: Int,
    private val dropNonResolvable: Boolean,
    private val allowlistExclusive: Boolean,
    private val rssiFloor: Int,
    private val rssiThreshold: Int,
    private val rssiMacAllowlist: Int,
    private val rssiIrk: Int,
    private val rssiServiceUuid: Int,
) {
    /** Counters, so the effect is measurable per panel rather than guessed. */
    @Volatile var forwarded: Long = 0L; private set
    @Volatile var dropped: Long = 0L; private set
    @Volatile var droppedRpa: Long = 0L; private set

    /** Advertisements forwarded *only* because a service UUID matched. It
     *  sits at zero while nothing is pairing, so any movement is direct
     *  evidence the passthrough fired -- which is what makes a failed
     *  commissioning attempt diagnosable instead of guesswork. */
    @Volatile var allowedServiceUuid: Long = 0L; private set

    private val hasServiceUuids = serviceUuids16.isNotEmpty() || serviceUuids128.isNotEmpty()

    /**
     * The loosest limit any category could apply, so an advertisement below
     * it cannot be kept by anything and need not be categorised. Nothing but
     * an optimisation, which is why it is computed from the same rules
     * [decide] applies rather than asserted alongside them.
     */
    private val preGate: Int = run {
        val limits = mutableListOf(bound(rssiThreshold))
        if (macAllowlist.isNotEmpty()) limits.add(bound(rssiMacAllowlist))
        if (irks.isNotEmpty()) limits.add(bound(if (rssiIrk != 0) rssiIrk else rssiThreshold))
        if (hasServiceUuids) {
            limits.add(bound(if (rssiServiceUuid != 0) rssiServiceUuid else rssiThreshold))
        }
        for (rule in ibeacons) {
            limits.add(if (rule.rssi != 0) rule.rssi else bound(rssiThreshold))
        }
        if (allowFindmy) limits.add(if (findmyRssi != 0) findmyRssi else bound(rssiThreshold))
        // 0 is unbounded, so one unbounded category disables the gate.
        if (limits.any { it == 0 }) 0 else limits.min()
    }

    /** The floor bounds a category that brought no limit of its own. */
    private fun bound(limit: Int): Int =
        if (rssiFloor != 0 && (limit == 0 || rssiFloor > limit)) rssiFloor else limit

    val active: Boolean
        get() = irks.isNotEmpty() || macAllowlist.isNotEmpty() ||
            macBlocklist.isNotEmpty() || manufacturerBlocklist.isNotEmpty() ||
            nameBlocklist.isNotEmpty() || hasServiceUuids || dropNonResolvable ||
            allowlistExclusive || rssiFloor != 0 || rssiThreshold != 0 ||
            ibeacons.isNotEmpty() || allowFindmy

    fun counters(): Map<String, Any> = mapOf(
        "forwarded" to forwarded,
        "dropped" to dropped,
        "droppedRpa" to droppedRpa,
        "allowedServiceUuid" to allowedServiceUuid,
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

    private enum class Category { DEFAULT, MAC, IRK, IBEACON, FINDMY, UUID }

    private fun decide(address: Long, addressType: Int, rssi: Int, payload: ByteArray): Boolean {
        // Ahead of every allow rule on purpose: the point of a blocklist is
        // "this panel does not handle this device", which a broader entry
        // must not be able to override.
        if (macBlocklist.contains(address)) return false
        if (preGate != 0 && rssi < preGate) return false

        var category = Category.DEFAULT
        // Cheapest first: a set lookup, then AES only for actual RPAs, then
        // payload walks last and only when something is configured to need one.
        if (macAllowlist.contains(address)) category = Category.MAC
        if (category == Category.DEFAULT && irks.isNotEmpty() &&
            isResolvable(address, addressType)
        ) {
            if (!irkMatches(address)) {
                // Somebody else's phone or watch: it rotates, so it can never
                // be tracked here. Dropped regardless of RSSI -- proximity
                // does not make an unidentifiable device identifiable.
                droppedRpa++
                return false
            }
            category = Category.IRK
        }
        // An iBeacon the owner named is protected like an allowlisted
        // address, and for the same reason: a tracked tag heard weakly here
        // is the measurement that places it nearer another proxy.
        var ownLimit = 0
        if (category == Category.DEFAULT && ibeacons.isNotEmpty()) {
            val rule = matchIbeacon(payload)
            if (rule != null) {
                category = Category.IBEACON
                ownLimit = rule.rssi
            }
        }
        // FindMy accessories: the same shape of rule as an iBeacon -- an
        // Apple manufacturer-data subtype exempted from the blocklist, with
        // an optional limit of its own -- in the same place in the chain.
        if (category == Category.DEFAULT && allowFindmy && matchesFindmy(payload)) {
            category = Category.FINDMY
            ownLimit = findmyRssi
        }
        // Last, and skipped entirely when unconfigured. Exists for devices
        // whose address cannot be known ahead of time: a device in pairing
        // mode advertises from a rotating private address, which the
        // non-resolvable test below would otherwise discard.
        if (category == Category.DEFAULT && hasServiceUuids &&
            payloadHasAllowedServiceUuid(payload)
        ) {
            category = Category.UUID
            allowedServiceUuid++
        }
        val protectedAdv = category != Category.DEFAULT

        var limit = when (category) {
            Category.MAC -> rssiMacAllowlist
            Category.IRK -> if (rssiIrk != 0) rssiIrk else rssiThreshold
            Category.UUID -> if (rssiServiceUuid != 0) rssiServiceUuid else rssiThreshold
            Category.IBEACON, Category.FINDMY ->
                if (ownLimit != 0) ownLimit else rssiThreshold
            Category.DEFAULT -> rssiThreshold
        }
        // The floor still bounds every category that did not bring its own.
        if (ownLimit == 0) limit = bound(limit)
        if (limit != 0 && rssi < limit) return false

        if (allowlistExclusive && !protectedAdv) return false
        if (dropNonResolvable && !protectedAdv && isNonResolvable(address, addressType)) return false
        if (!protectedAdv && (manufacturerBlocklist.isNotEmpty() || nameBlocklist.isNotEmpty()) &&
            payloadBlocked(payload)
        ) {
            return false
        }
        return true
    }

    /**
     * Walks the advertising data as AD structures -- [length][type][data] --
     * handing each one's type, the offset of its first data byte and that
     * data's length to [body], stopping at the first `true`. A structure
     * claiming to run past the buffer ends the walk: a truncated packet is
     * not a reason to read off the end of one.
     */
    private inline fun walkAd(
        payload: ByteArray,
        body: (type: Int, start: Int, length: Int) -> Boolean,
    ): Boolean {
        var index = 0
        while (index < payload.size) {
            val fieldLen = payload[index].toInt() and 0xFF
            if (fieldLen == 0) return false
            if (index + 1 + fieldLen > payload.size) return false
            if (body(payload[index + 1].toInt() and 0xFF, index + 2, fieldLen - 1)) return true
            index += 1 + fieldLen
        }
        return false
    }

    /**
     * iBeacon is Apple manufacturer data (company 0x004C) with subtype 0x02
     * and length 0x15, carrying a 16-byte UUID then big-endian major and
     * minor. Parsed here rather than trusted from a name, since the name is
     * the one field a beacon need not carry.
     */
    private fun matchIbeacon(payload: ByteArray): IBeaconRule? {
        var found: IBeaconRule? = null
        walkAd(payload) { type, start, length ->
            // 004C, 02, 15, 16-byte uuid, major, minor = 24 data bytes.
            if (type == 0xFF && length >= 24 &&
                (payload[start].toInt() and 0xFF) == 0x4C &&
                (payload[start + 1].toInt() and 0xFF) == 0x00 &&
                (payload[start + 2].toInt() and 0xFF) == 0x02 &&
                (payload[start + 3].toInt() and 0xFF) == 0x15
            ) {
                val uuid = StringBuilder(32)
                for (i in 0 until 16) {
                    uuid.append("%02x".format(payload[start + 4 + i].toInt() and 0xFF))
                }
                val major = ((payload[start + 20].toInt() and 0xFF) shl 8) or
                    (payload[start + 21].toInt() and 0xFF)
                val minor = ((payload[start + 22].toInt() and 0xFF) shl 8) or
                    (payload[start + 23].toInt() and 0xFF)
                val hex = uuid.toString()
                found = ibeacons.firstOrNull { it.matches(hex, major, minor) }
            }
            found != null
        }
        return found
    }

    /**
     * Apple Offline Finding: manufacturer data, company 0x004C, subtype
     * 0x12. AirTags, AirPods in separated mode and licensed third-party tags
     * advertise this from a random static address, so neither the IRK test
     * nor [dropNonResolvable] sees them and only an Apple entry in
     * [manufacturerBlocklist] ever stands in their way.
     *
     * The rest of the payload -- a status byte and 22 bytes of public key --
     * carries no identity a panel could act on: the address rotation is
     * resolvable only with the accessory's pairing keys, which live in the
     * tracker. So there is no per-accessory scoping, and every FindMy tag in
     * range comes through; [findmyRssi] is how that is bounded.
     */
    private fun matchesFindmy(payload: ByteArray): Boolean =
        walkAd(payload) { type, start, length ->
            type == 0xFF && length >= 3 &&
                (payload[start].toInt() and 0xFF) == 0x4C &&
                (payload[start + 1].toInt() and 0xFF) == 0x00 &&
                (payload[start + 2].toInt() and 0xFF) == 0x12
        }

    /**
     * One pass for both payload blocklists, so a dropped advertisement is
     * never walked twice.
     */
    private fun payloadBlocked(payload: ByteArray): Boolean =
        walkAd(payload) { type, start, length ->
            var blocked = false
            // 0xFF manufacturer specific data: the first two data bytes are
            // the Bluetooth SIG company identifier, little-endian.
            if (type == 0xFF && length >= 2) {
                val company = (payload[start].toInt() and 0xFF) or
                    ((payload[start + 1].toInt() and 0xFF) shl 8)
                // HomeKit accessories advertise under Apple's company id with
                // subtype 0x06. Blocklisting Apple to kill phone and AirTag
                // noise would take them with it, and unlike phones they carry
                // no IRK to rescue them, so exempt HAP explicitly rather than
                // forcing a choice between the two.
                val isHap = allowHomekit && company == 0x004C && length >= 3 &&
                    (payload[start + 2].toInt() and 0xFF) == 0x06
                if (!isHap && manufacturerBlocklist.contains(company)) blocked = true
            }
            // 0x09 complete local name, 0x08 shortened local name.
            if (!blocked && (type == 0x09 || type == 0x08) && length > 0) {
                val name = String(payload, start, length, Charsets.ISO_8859_1).lowercase()
                if (nameBlocklist.any { name.contains(it) }) blocked = true
            }
            blocked
        }

    /**
     * A service UUID can appear in several places and a device in pairing
     * mode does not consistently use one, so every form is checked:
     * 0x02/0x03 16-bit lists, 0x14 16-bit solicitation, 0x16 16-bit service
     * data, 0x06/0x07 128-bit lists, 0x15 128-bit solicitation and 0x21
     * 128-bit service data. The list types carry a packed array; the
     * service-data types carry exactly one UUID and then opaque bytes, so
     * those stop after the first entry.
     */
    private fun payloadHasAllowedServiceUuid(payload: ByteArray): Boolean =
        walkAd(payload) { type, start, length ->
            var hit = false
            if (serviceUuids16.isNotEmpty() &&
                (type == 0x02 || type == 0x03 || type == 0x14 || type == 0x16)
            ) {
                val entries = length / 2
                val count = if (type == 0x16) minOf(entries, 1) else entries
                for (i in 0 until count) {
                    val uuid = (payload[start + i * 2].toInt() and 0xFF) or
                        ((payload[start + i * 2 + 1].toInt() and 0xFF) shl 8)
                    if (serviceUuids16.contains(uuid)) { hit = true; break }
                }
            }
            // The long form can match a 16-bit entry through the SIG base
            // UUID, so this arm runs whenever either list is configured.
            if (!hit && (type == 0x06 || type == 0x07 || type == 0x15 || type == 0x21)) {
                val entries = length / 16
                val count = if (type == 0x21) minOf(entries, 1) else entries
                for (i in 0 until count) {
                    if (uuid128Matches(payload, start + i * 16)) { hit = true; break }
                }
            }
            hit
        }

    /** 128-bit UUIDs are transmitted little-endian, so [offset] is read in
     *  reverse to get canonical order before comparing. */
    private fun uuid128Matches(payload: ByteArray, offset: Int): Boolean {
        val canonical = ByteArray(16) { payload[offset + 15 - it] }
        for (entry in serviceUuids128) {
            if (entry.contentEquals(canonical)) return true
        }
        if (serviceUuids16.isEmpty()) return false
        val short = shortFromBaseUuid(canonical) ?: return false
        return serviceUuids16.contains(short)
    }

    /**
     * One initialised cipher per identity key, built on first use.
     * Cipher.getInstance() walks the provider list and init() expands the key
     * schedule; doing both for every key on every resolvable advertisement
     * was most of what resolution cost. Null when the platform refuses AES,
     * which resolves nothing -- the same answer the per-call version gave.
     */
    private val irkCiphers: List<Cipher>? by lazy(LazyThreadSafetyMode.NONE) {
        try {
            irks.map { key ->
                Cipher.getInstance("AES/ECB/NoPadding").apply {
                    init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
                }
            }
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Addresses already tested against the keys. A private address holds for
     * about fifteen minutes and advertises several times a second throughout,
     * and whether it resolves depends only on the address and the keys, which
     * are fixed for the life of this filter -- so an answer never goes stale
     * and the memo only needs a bound. Least recently seen goes first.
     */
    private val resolved = object : LinkedHashMap<Long, Boolean>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, Boolean>?) =
            size > RESOLVED_CACHE_SIZE
    }

    /**
     * Bluetooth Core "ah": hash = e(IRK, 0-padding | prand) truncated to 24
     * bits, where an RPA is prand (top three bytes) followed by hash (bottom
     * three).
     *
     * Locked because a Cipher is not safe to share between threads and
     * nothing here promises which thread a scan result arrives on.
     */
    private fun irkMatches(address: Long): Boolean = synchronized(resolved) {
        resolved[address]?.let { return it }
        val matched = resolves(address)
        resolved[address] = matched
        matched
    }

    private fun resolves(address: Long): Boolean {
        val ciphers = irkCiphers ?: return false
        val plaintext = ByteArray(16)
        plaintext[13] = ((address shr 40) and 0xFF).toByte()
        plaintext[14] = ((address shr 32) and 0xFF).toByte()
        plaintext[15] = ((address shr 24) and 0xFF).toByte()
        for (cipher in ciphers) {
            val out = try {
                cipher.doFinal(plaintext)
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

    companion object {
        /** Distinct private addresses remembered; a busy room holds a few dozen. */
        private const val RESOLVED_CACHE_SIZE = 512

        /** 0000xxxx-0000-1000-8000-00805F9B34FB, the suffix a SIG short
         *  carries when it is advertised in its long form. */
        private val BASE_UUID_SUFFIX = byteArrayOf(
            0x00, 0x00, 0x10, 0x00, 0x80.toByte(), 0x00,
            0x00, 0x80.toByte(), 0x5F, 0x9B.toByte(), 0x34, 0xFB.toByte(),
        )

        /** The 16-bit short a canonical 128-bit UUID stands for, or null if
         *  it is not a SIG base UUID at all. */
        private fun shortFromBaseUuid(canonical: ByteArray): Int? {
            if (canonical.size != 16) return null
            if (canonical[0].toInt() != 0 || canonical[1].toInt() != 0) return null
            for (i in 0 until 12) {
                if (canonical[4 + i] != BASE_UUID_SUFFIX[i]) return null
            }
            return ((canonical[2].toInt() and 0xFF) shl 8) or (canonical[3].toInt() and 0xFF)
        }

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
            val manufacturers = mutableSetOf<Int>()
            root.optJSONArray("manufacturers")?.let { array ->
                for (i in 0 until array.length()) {
                    numberOrHex(array.opt(i))?.takeIf { it in 0..0xFFFF }?.let(manufacturers::add)
                }
            }
            val names = mutableListOf<String>()
            root.optJSONArray("names")?.let { array ->
                for (i in 0 until array.length()) {
                    array.optString(i).trim().lowercase().takeIf { it.isNotEmpty() }?.let(names::add)
                }
            }
            // A short written in its long form is normalised here rather
            // than at match time, so either spelling costs the same walk.
            val uuids16 = mutableSetOf<Int>()
            val uuids128 = mutableListOf<ByteArray>()
            root.optJSONArray("serviceUuids")?.let { array ->
                for (i in 0 until array.length()) {
                    val raw = array.opt(i)
                    val clean = (raw as? String)?.trim()?.replace("-", "")?.replace(":", "")
                    if (clean != null && clean.length == 32) {
                        val bytes = hexToBytes(clean, 16) ?: continue
                        val short = shortFromBaseUuid(bytes)
                        if (short != null) uuids16.add(short) else uuids128.add(bytes)
                    } else {
                        numberOrHex(raw)?.takeIf { it in 0..0xFFFF }?.let(uuids16::add)
                    }
                }
            }
            val ibeacons = mutableListOf<IBeaconRule>()
            root.optJSONArray("ibeacons")?.let { array ->
                for (i in 0 until array.length()) {
                    val rule = array.optJSONObject(i) ?: continue
                    val prefix = rule.optString("uuidPrefix")
                        .replace("-", "").replace(":", "").lowercase()
                    ibeacons.add(
                        IBeaconRule(
                            uuidPrefix = prefix,
                            major = if (rule.has("major")) rule.optInt("major") else null,
                            minor = if (rule.has("minor")) rule.optInt("minor") else null,
                            rssi = rule.optInt("rssi", 0),
                        )
                    )
                }
            }
            // allowFindmy takes true, or an object carrying a limit of its
            // own -- the same two spellings the ESPHome option accepts.
            val findmy = root.opt("allowFindmy")
            val allowFindmy = findmy == true || findmy is JSONObject
            val findmyRssi = (findmy as? JSONObject)?.optInt("rssi", 0) ?: 0
            val filter = AdvertisementFilter(
                irks = irks,
                ibeacons = ibeacons,
                macAllowlist = macSet(root.optJSONArray("macs")),
                macBlocklist = macSet(root.optJSONArray("macBlocklist")),
                manufacturerBlocklist = manufacturers,
                nameBlocklist = names,
                serviceUuids16 = uuids16,
                serviceUuids128 = uuids128,
                allowHomekit = root.optBoolean("allowHomekit", false),
                allowFindmy = allowFindmy,
                findmyRssi = findmyRssi,
                dropNonResolvable = root.optBoolean("dropNonResolvable", false),
                allowlistExclusive = root.optBoolean("allowlistExclusive", false),
                rssiFloor = root.optInt("rssiFloor", 0),
                rssiThreshold = root.optInt("rssiThreshold", 0),
                rssiMacAllowlist = root.optInt("rssiMacAllowlist", 0),
                rssiIrk = root.optInt("rssiIrk", 0),
                rssiServiceUuid = root.optInt("rssiServiceUuid", 0),
            )
            return if (filter.active) filter else null
        }

        private fun macSet(array: JSONArray?): Set<Long> {
            if (array == null) return emptySet()
            val macs = mutableSetOf<Long>()
            for (i in 0 until array.length()) {
                macToLong(array.optString(i))?.let(macs::add)
            }
            return macs
        }

        /** Company ids and 16-bit UUIDs are written either way round in the
         *  YAML this mirrors, so both spellings are accepted here. */
        private fun numberOrHex(raw: Any?): Int? = when (raw) {
            is Number -> raw.toInt()
            is String -> raw.trim().removePrefix("0x").removePrefix("0X").toIntOrNull(16)
            else -> null
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
