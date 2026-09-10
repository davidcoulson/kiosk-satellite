package me.jxl.kiosk_satellite

import android.util.Log

/**
 * JNI binding for the app-direct /dev/ledjni access path (see led_jni.cpp,
 * led_ioctl.h). Only reachable on panels where the node is openable by a
 * normal app process; [LedBridge] falls back to [LedHelperProcess] (`su -c`
 * against the bundled led_helper executable) when it is not.
 *
 * Values passed to [nativeSetRgb] are already scaled by the caller (see
 * [LedBridge]'s channel transfer) — this object issues the ioctls verbatim.
 */
object NativeLed {
    private val loaded: Boolean = try {
        System.loadLibrary("led_jni")
        true
    } catch (e: Throwable) {
        Log.i(TAG, "libled_jni not loadable on this ABI — LED native disabled", e)
        false
    }

    /** True only when the native lib loaded AND /dev/ledjni is openable directly. */
    fun available(): Boolean = loaded && nativeProbe()

    external fun nativeProbe(): Boolean
    external fun nativeSetRgb(r: Int, g: Int, b: Int): Int
    external fun nativeOff(): Int

    private const val TAG = "ks/led-ndk"
}
