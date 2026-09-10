// JNI bridge between the Kotlin NativeLed object and the /dev/ledjni ioctl
// protocol in led_ioctl.h. Used on the app-direct path: panels where the
// node is openable by a normal (non-rooted) app process. See NativeLed.kt
// and LedBridge.kt for how a panel that can't open the node directly falls
// back to led_helper.cpp instead.

#include <jni.h>
#include <android/log.h>

#include "led_ioctl.h"

namespace {
constexpr const char* kTag = "kiosk-satellite/led-ndk";
}

extern "C" JNIEXPORT jboolean JNICALL
Java_me_jxl_kiosk_1satellite_NativeLed_nativeProbe(JNIEnv* /*env*/, jobject /*thiz*/) {
    return led_ioctl::probe() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_me_jxl_kiosk_1satellite_NativeLed_nativeSetRgb(JNIEnv* /*env*/, jobject /*thiz*/,
                                                     jint r, jint g, jint b) {
    int rc = led_ioctl::set_rgb(r, g, b);
    if (rc != 0) {
        __android_log_print(ANDROID_LOG_WARN, kTag, "setRgb failed rc=%d", rc);
    }
    return rc;
}

extern "C" JNIEXPORT jint JNICALL
Java_me_jxl_kiosk_1satellite_NativeLed_nativeOff(JNIEnv* /*env*/, jobject /*thiz*/) {
    int rc = led_ioctl::off();
    if (rc != 0) {
        __android_log_print(ANDROID_LOG_WARN, kTag, "off failed rc=%d", rc);
    }
    return rc;
}
