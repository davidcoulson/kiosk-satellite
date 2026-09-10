# Native SendSpin engine: sendspin-cpp (the protocol reference implementation)
# plus a JNI bridge. The library is fetched pinned to a release commit; its own
# dependencies (ArduinoJson, micro-flac, micro-opus, IXWebSocket) are fetched
# transitively by its build.
cmake_minimum_required(VERSION 3.22)
project(kiosk_satellite_native LANGUAGES CXX)

include(FetchContent)

# v0.7.0
FetchContent_Declare(
    sendspin_cpp
    GIT_REPOSITORY https://github.com/Sendspin/sendspin-cpp.git
    GIT_TAG        254603c283bc137aa2f748ff5b2c99a39c56faf2
)

# Player, controller, and metadata are the roles the app uses. Artwork arrives
# via the metadata artwork_url, and the spectrum tap runs on decoded PCM in the
# shell, so those roles stay out of the binary.
set(SENDSPIN_ENABLE_ARTWORK OFF CACHE BOOL "" FORCE)
set(SENDSPIN_ENABLE_COLOR OFF CACHE BOOL "" FORCE)
set(SENDSPIN_ENABLE_VISUALIZER OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(sendspin_cpp)

add_library(sendspin_jni SHARED sendspin_jni.cpp)

target_compile_features(sendspin_jni PRIVATE cxx_std_20)
target_compile_options(sendspin_jni PRIVATE -Wall -Wextra)

find_library(log-lib log)
target_link_libraries(sendspin_jni PRIVATE sendspin ${log-lib})

# /dev/ledjni RGB LED driver (see led_ioctl.h). Two consumers of the same
# ioctl logic: a JNI binding for the app-direct access path, and a
# standalone CLI for the rooted-fallback path (LedBridge.kt runs it via
# `su -c`, for panels that SELinux-deny the node to a normal app process).
add_library(led_jni SHARED led_jni.cpp)
target_compile_features(led_jni PRIVATE cxx_std_20)
target_compile_options(led_jni PRIVATE -Wall -Wextra)
target_link_libraries(led_jni PRIVATE ${log-lib})

# Named/suffixed like a shared library (rather than the target's natural
# "led_helper" with no prefix/suffix) so Gradle's jniLibs packaging picks it
# up and extracts it as a real per-ABI file under nativeLibraryDir, even
# though it's actually a plain executable, not a loadable library. See
# app/build.gradle.kts's `packaging { jniLibs { useLegacyPackaging = true } }`
# — without that, modern AGP mmaps .so files straight out of the APK instead
# of extracting them to disk, and there would be no real file path to exec.
add_executable(led_helper led_helper.cpp)
set_target_properties(led_helper PROPERTIES
    PREFIX "lib"
    SUFFIX ".so"
    OUTPUT_NAME "led_helper"
)
target_compile_features(led_helper PRIVATE cxx_std_20)
target_compile_options(led_helper PRIVATE -Wall -Wextra)
