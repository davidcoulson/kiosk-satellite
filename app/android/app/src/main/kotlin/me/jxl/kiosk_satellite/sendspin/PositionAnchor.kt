package me.jxl.kiosk_satellite.sendspin

/**
 * A track position the client adopted on its own, ahead of the server's
 * next metadata report: a seek it sent, the queue time Music Assistant
 * reported when the engine's progress went stale, or the start of the
 * track after a previous command restarted it.
 *
 * Music Assistant restarts the stream for a seek or a previous without a
 * fresh progress report, so the engine keeps counting from the report
 * before. The anchor holds its own position and moves it on the clock
 * while the stream plays. It must not ride on the engine's progress: the
 * engine stops counting at the track's duration, and a position tied to it
 * would stop with it and send the same value with every push.
 *
 * All times are elapsed-realtime milliseconds passed in by the caller.
 */
class PositionAnchor {
    companion object {
        /** How long after a previous command a stream start counts as its restart. */
        const val PREVIOUS_RESTART_WINDOW_MS = 5_000L
    }

    private var positionMs = -1L
    private var at = 0L
    private var running = false
    private var previousSentAt = -1L

    val isSet: Boolean @Synchronized get() = positionMs >= 0

    /** Adopt [positionMs] as the position at [now]. */
    @Synchronized
    fun set(positionMs: Long, now: Long, running: Boolean) {
        this.positionMs = positionMs.coerceAtLeast(0L)
        at = now
        this.running = running
    }

    /** A real server report arrived: the engine's progress is right again. */
    @Synchronized
    fun clear() {
        positionMs = -1L
        previousSentAt = -1L
    }

    /** The stream started or stopped: the position moves only while it plays. */
    @Synchronized
    fun setRunning(running: Boolean, now: Long) {
        if (running == this.running) return
        if (positionMs >= 0) {
            if (this.running) positionMs += now - at
            at = now
        }
        this.running = running
    }

    /** The adopted position at [now], held to [durationMs] when known, or null with none adopted. */
    @Synchronized
    fun current(now: Long, durationMs: Long): Long? {
        if (positionMs < 0) return null
        val pos = positionMs + if (running) now - at else 0L
        return if (durationMs > 0) pos.coerceAtMost(durationMs) else pos
    }

    @Synchronized
    fun previousSent(now: Long) {
        previousSentAt = now
    }

    /**
     * A stream started at [now]. True when it is the restart a previous
     * command just asked for, which puts the anchor at the track's start.
     * When the previous moved to another track instead, that track's
     * metadata clears the anchor again.
     */
    @Synchronized
    fun onStreamStart(now: Long): Boolean {
        val sent = previousSentAt
        previousSentAt = -1L
        if (sent < 0 || now - sent > PREVIOUS_RESTART_WINDOW_MS) return false
        set(0L, now, running = true)
        return true
    }
}
