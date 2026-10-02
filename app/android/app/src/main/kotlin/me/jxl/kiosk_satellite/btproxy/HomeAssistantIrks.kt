package me.jxl.kiosk_satellite.btproxy

/**
 * The advertisement filter's identity keys, taken from a Home Assistant
 * entity: the Android side of the ESP proxies' irks-from-ha.yaml, so a new
 * phone is added once in Home Assistant and every panel and proxy picks it
 * up, with no setting to edit on each.
 *
 * Opt-in through the filter's `irksEntity` (and `irksAttribute`, "" for the
 * state); without one this does not exist and nothing is asked for. The
 * house keeps the keys in an attribute rather than the state, because Home
 * Assistant caps a state at 255 characters and eight keys are 256 hex
 * characters before any separator or name.
 *
 * Semantics are the ESP package's:
 *
 *  - Every run of exactly 32 hex digits in the value is a key, so a name may
 *    sit beside each one ("David phone: 0011..."). A longer run is something
 *    else (a hash, a UUID without dashes) and is not cut into one.
 *  - A value with no key in it -- unavailable, unknown, empty, the gap while
 *    Home Assistant restarts -- is ignored and the current list kept. That
 *    matters: with Apple on the manufacturer blocklist, a wiped list would
 *    silently drop the household's own phones.
 *  - The literal `clear` empties the list, which hands the filter back to
 *    the btproxy.filter_irks setting's keys (see
 *    [AdvertisementFilter.useHomeAssistantIrks]).
 *  - Anything else replaces the list.
 *
 * The last list Home Assistant delivered is kept on the device through
 * [Store] and used from boot until Home Assistant connects and sends one,
 * so a reboot does not open a window in which those phones are strangers.
 * It must stay out of settings exports for the same reason the setting's
 * keys are secret: an IRK identifies a person's phone wherever it goes.
 *
 * Pure JVM, like the server it plugs into, so it runs under unit tests.
 */
internal class HomeAssistantIrks(
    private val filter: AdvertisementFilter,
    private val store: Store,
    private val log: (String) -> Unit,
) : HomeAssistantStateBackend {
    /** Where the last delivered list survives a restart: the keys as one
     *  comma-separated hex string, "" for none. */
    interface Store {
        fun load(): String
        fun save(keys: String)
    }

    private val entityId = filter.irksEntity
    private val attribute = filter.irksAttribute

    /** The list Home Assistant delivered last, as the hex [Store] holds. */
    private var current = ""

    override val subscriptions: List<Pair<String, String>> =
        if (entityId.isEmpty()) emptyList() else listOf(entityId to attribute)

    init {
        val saved = runCatching { store.load() }.getOrDefault("")
        val keys = extract(saved)
        if (keys != null) {
            current = toHex(keys)
            filter.useHomeAssistantIrks(keys)
            log("IRKs: ${keys.size} from the last Home Assistant list until it connects")
        }
    }

    @Synchronized
    override fun onState(entityId: String, attribute: String, state: String) {
        if (entityId != this.entityId || attribute != this.attribute) return
        val keys = if (state.trim().equals("clear", ignoreCase = true)) {
            emptyList()
        } else {
            // No key at all: an entity mid-restart, not an instruction.
            extract(state) ?: return
        }
        val hex = toHex(keys)
        // Home Assistant resends the value on every reconnect; only a
        // change is worth a swap, a write and a log line.
        if (hex == current) return
        current = hex
        filter.useHomeAssistantIrks(keys)
        runCatching { store.save(hex) }
        // The count only, never the keys: this log leaves the device in
        // the proxy's diagnostics.
        log(
            if (keys.isEmpty()) {
                "IRKs: Home Assistant cleared its list; using the setting's keys"
            } else {
                "IRKs: ${keys.size} from Home Assistant"
            }
        )
    }

    companion object {
        /** The ESP proxies' bound: every key costs an AES block per
         *  unresolved advertisement, and this text arrives from outside. */
        const val MAX_KEYS = 16

        /** Exactly 32 hex digits with no hex digit either side. */
        private val KEY = Regex("(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])")

        /** Every key in [value], deduplicated and bounded; null when there
         *  is none, which callers treat as "keep what you have". */
        fun extract(value: String): List<ByteArray>? {
            val keys = mutableListOf<ByteArray>()
            for (match in KEY.findAll(value)) {
                val key = AdvertisementFilter.hexToBytes(match.value, 16) ?: continue
                if (keys.any { it.contentEquals(key) }) continue
                if (keys.size >= MAX_KEYS) break
                keys.add(key)
            }
            return keys.ifEmpty { null }
        }

        private fun toHex(keys: List<ByteArray>): String =
            keys.joinToString(",") { key -> key.joinToString("") { "%02x".format(it) } }
    }
}
