package me.jxl.kiosk_satellite

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * The panel's front RGB LED, reached through the vendor char device
 * `/dev/ledjni` (protocol: [NativeLed] / led_ioctl.h). Two access paths,
 * because which one works is per-panel, not something this app can know in
 * advance (see led_ioctl.h's header comment and the ha-paneld project it
 * credits):
 *
 * - **Direct**: the node is openable by this (normal, non-rooted-relative)
 *   app process — [NativeLed] issues the ioctls itself.
 * - **Root helper**: the node is SELinux-denied to a normal app; `su -c`
 *   runs the bundled `led_helper` executable instead, which (run as root)
 *   is generally unconfined by that same restriction.
 *
 * Neither being usable (no root, no direct access) leaves the LED
 * unavailable — same convention as every other hardware-gated bridge here
 * (no camera, no light sensor, etc.): the Dart side simply does not publish
 * the entity rather than publishing one that always fails.
 *
 * Detection runs on a background thread (an unauthorized `su` request can
 * block on an interactive grant dialog from the root manager) and pushes
 * the resolved state to Dart once known, rather than blocking app startup.
 *
 * r/g/b are 0..255 (Home Assistant's range); [LedChannelScale] scales that
 * down to the low-drive region that reproduces colour accurately on the
 * hardware ha-paneld probed — see led_ioctl.h. This is a stub pending
 * calibration on the actual panel this runs on.
 */
class LedBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "kiosk_satellite/led")
    private val mainHandler = Handler(Looper.getMainLooper())

    private enum class Mode { DETECTING, DIRECT, ROOT_HELPER, UNAVAILABLE }

    @Volatile private var mode = Mode.DETECTING
    @Volatile private var helperPath: String? = null

    /** Why detection landed on [Mode.UNAVAILABLE], for the Settings row —
     *  see [detect]. Null once a working mode is found. */
    @Volatile private var hint: String? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(mode == Mode.DIRECT || mode == Mode.ROOT_HELPER)
                "hint" -> result.success(hint)
                "setRgb" -> {
                    val r = (call.argument<Number>("r"))?.toInt() ?: 0
                    val g = (call.argument<Number>("g"))?.toInt() ?: 0
                    val b = (call.argument<Number>("b"))?.toInt() ?: 0
                    result.success(setRgb(r, g, b))
                }
                "off" -> result.success(off())
                else -> result.notImplemented()
            }
        }
        thread(name = "led-detect") { detect() }
    }

    /** invokeMethod must run on the platform thread; [detect] runs on its
     *  own background thread (an unauthorized `su` probe can block on an
     *  interactive grant dialog), so the call is posted across. */
    private fun pushAvailable() {
        val available = mode == Mode.DIRECT || mode == Mode.ROOT_HELPER
        mainHandler.post { channel.invokeMethod("available", available) }
    }

    private fun detect() {
        if (NativeLed.available()) {
            mode = Mode.DIRECT
            Log.i(TAG, "LED: direct access to /dev/ledjni")
            pushAvailable()
            return
        }
        // Distinguishes "no such hardware" from "hardware present but
        // unreachable" for the Settings row's explanation — the probe
        // above only reports a bare open() failure, not why.
        val nodeExists = File(LED_DEVICE_PATH).exists()
        val helper = resolveHelper()
        if (nodeExists && helper != null && isRooted() && probeHelper(helper)) {
            helperPath = helper
            mode = Mode.ROOT_HELPER
            Log.i(TAG, "LED: root-helper access to /dev/ledjni ($helper)")
        } else {
            mode = Mode.UNAVAILABLE
            hint = when {
                !nodeExists ->
                    "This panel has no /dev/ledjni device — this model likely " +
                        "has no controllable status LED, or the vendor uses a " +
                        "different device node this app doesn't know about."
                !isRooted() ->
                    "/dev/ledjni exists but this app can't open it directly, " +
                        "and the device isn't rooted (or Magisk wasn't found) " +
                        "for the fallback path. Root access (e.g. via Magisk) " +
                        "is needed to reach this panel's LED."
                else ->
                    "/dev/ledjni exists and the device is rooted, but even " +
                        "root access couldn't reach it — this panel's " +
                        "permissions may need a custom fix for this hardware."
            }
            Log.i(TAG, "LED: unavailable — $hint")
        }
        pushAvailable()
    }

    /** The bundled led_helper executable, extracted alongside the app's real
     *  native libraries — see build.gradle.kts's useLegacyPackaging note. */
    private fun resolveHelper(): String? {
        val dir = context.applicationInfo.nativeLibraryDir ?: return null
        val f = File(dir, "libled_helper.so")
        return f.takeIf { it.exists() }?.absolutePath
    }

    private fun isRooted(): Boolean = try {
        val p = ProcessBuilder("su", "-c", "id").redirectErrorStream(true).start()
        val finished = p.waitFor(ROOT_PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (!finished) {
            p.destroyForcibly()
            false
        } else {
            p.exitValue() == 0
        }
    } catch (_: Exception) {
        false
    }

    private fun probeHelper(path: String): Boolean = runHelper(path, "probe") == 0

    /** Runs led_helper via `su -c`, returning its exit code, or null on a
     *  process-level failure (su missing, timeout, etc). */
    private fun runHelper(path: String, vararg args: String): Int? = try {
        val cmd = (listOf(path) + args).joinToString(" ")
        val p = ProcessBuilder("su", "-c", cmd).redirectErrorStream(true).start()
        val finished = p.waitFor(HELPER_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (!finished) {
            p.destroyForcibly()
            null
        } else {
            p.exitValue()
        }
    } catch (e: Exception) {
        Log.w(TAG, "led_helper invocation failed", e)
        null
    }

    private fun setRgb(r: Int, g: Int, b: Int): Boolean {
        val (hr, hg, hb) = Triple(scale(r), scale(g), scale(b))
        return when (mode) {
            Mode.DIRECT -> {
                val rc = NativeLed.nativeSetRgb(hr, hg, hb)
                if (rc != 0) Log.w(TAG, "setRgb failed rc=$rc")
                rc == 0
            }
            Mode.ROOT_HELPER -> {
                val path = helperPath ?: return false
                val rc = runHelper(path, "setrgb", "$hr", "$hg", "$hb")
                if (rc != 0) Log.w(TAG, "setRgb (root helper) failed rc=$rc")
                rc == 0
            }
            else -> false
        }
    }

    private fun off(): Boolean = when (mode) {
        Mode.DIRECT -> {
            val rc = NativeLed.nativeOff()
            if (rc != 0) Log.w(TAG, "off failed rc=$rc")
            rc == 0
        }
        Mode.ROOT_HELPER -> {
            val path = helperPath ?: return false
            val rc = runHelper(path, "off")
            if (rc != 0) Log.w(TAG, "off (root helper) failed rc=$rc")
            rc == 0
        }
        else -> false
    }

    /** 0..255 (Home Assistant's range) down to the panel's safe low-drive
     *  region — see [LedChannelScale]. */
    private fun scale(v: Int) = LedChannelScale.toHardware(v)

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val TAG = "ks/led-bridge"
        // Kept in sync by hand with led_ioctl.h's kDevPath: this file only
        // needs the path string for existence/hint purposes, not the ioctls.
        const val LED_DEVICE_PATH = "/dev/ledjni"
        const val ROOT_PROBE_TIMEOUT_MS = 4000L
        const val HELPER_TIMEOUT_MS = 2000L
    }
}
