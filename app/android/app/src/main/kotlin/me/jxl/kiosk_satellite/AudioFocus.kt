package me.jxl.kiosk_satellite

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Transient audio focus held for the length of a voice interaction, so
 * other apps' music (Poweramp, Spotify) ducks the way Android apps expect
 * and comes back when the interaction ends.
 *
 * Our own players never take focus (every ExoPlayer runs with
 * handleAudioFocus off) and Android does not duck the focus holder, so
 * Sendspin keeps following its own duck setting. How far another app
 * drops is up to Android or that app. Apps playing speech (podcasts,
 * audiobooks) usually pause instead and resume on release.
 */
object AudioFocus {
    private const val TAG = "AudioFocus"

    private val listener = AudioManager.OnAudioFocusChangeListener { change ->
        Log.i(TAG, "focus change $change")
    }

    private var request: AudioFocusRequest? = null
    private var held = false

    /** Take or release focus. Called on the main thread. */
    fun hold(context: Context, active: Boolean) {
        if (active == held) return
        val am = context.applicationContext
            .getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (active) {
            val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ASSISTANT)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build(),
                    )
                    .setOnAudioFocusChangeListener(listener)
                    .build()
                request = focus
                am.requestAudioFocus(focus)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    listener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
                )
            }
            // A refusal (a phone call, or no foreground service on Android
            // 15) leaves other apps playing. Releasing later is harmless.
            Log.i(TAG, "requested, result $result")
            held = true
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                request?.let { am.abandonAudioFocusRequest(it) }
                request = null
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(listener)
            }
            Log.i(TAG, "released")
            held = false
        }
    }
}
