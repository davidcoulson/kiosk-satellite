// Driver for the Rockchip RK3576-class panel front RGB LED, reached through
// the vendor char device /dev/ledjni.
//
// Protocol (ioctl request numbers, value range): a binary interop fact
// about the hardware, not vendor code. It was clean-room reverse-engineered
// and hardware-probed by the ha-paneld project
// (https://github.com/maxlyth/ha-paneld, app/src/main/cpp/led_jni.c) from
// disassembly of the vendor libjnielc.so; this file is our own
// implementation of the same documented facts, not a copy of theirs and no
// vendor bytes.
//
//   ioctl(fd, 0xa1, R); ioctl(fd, 0xa2, G); ioctl(fd, 0xa3, B)
//   all-off: ioctl(fd, 0x99, 0)
//
// ha-paneld's own documented open call is O_RDONLY. On this panel (a
// WF2489T) that opens the node fine but the write ioctls above fail with
// EACCES (errno 13) — this kernel driver checks the fd's write mode before
// honoring a state-changing ioctl, evidently unlike whatever panel ha-paneld
// probed. O_RDWR here is what real on-device testing required; kept
// world-open (no O_WRONLY) since the node may support reads elsewhere.
//
// The node accepts a per-channel value 0..255, but the LED's response is
// non-linear (a channel ramps 15->31->63->127->255) and driving the high
// end shifts the colour rather than just brightening it. Callers are
// expected to pre-scale into whatever range reproduces colour accurately on
// their specific panel (see LedTransfer.kt) before calling led_set_rgb;
// this header does no scaling of its own.
//
// Shared as a header (not a .cpp) because it backs two separate binaries:
// led_jni.cpp (JNI, for the app-direct path) and led_helper.cpp (a
// standalone CLI, for the rooted-fallback path) - the ioctl logic itself
// must exist exactly once.

#pragma once

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>

namespace led_ioctl {

constexpr const char* kDevPath = "/dev/ledjni";
constexpr int kIoctlRed = 0xa1;
constexpr int kIoctlGreen = 0xa2;
constexpr int kIoctlBlue = 0xa3;
constexpr int kIoctlOff = 0x99;

// Open the LED node. Returns fd >= 0, or -1 with errno set. O_RDWR (not
// ha-paneld's documented O_RDONLY) — see the header comment on why.
inline int open_device() {
    return open(kDevPath, O_RDWR | O_NOCTTY);
}

// True if the node exists and this process can open it. Issues no ioctls.
inline bool probe() {
    int fd = open_device();
    if (fd < 0) return false;
    close(fd);
    return true;
}

// Set R/G/B (each already scaled by the caller). Returns 0 on success,
// -errno on failure (including "couldn't open the node" as -errno from the
// open() call itself).
inline int set_rgb(int r, int g, int b) {
    int fd = open_device();
    if (fd < 0) return -errno;
    int rc = 0;
    if (ioctl(fd, kIoctlRed, r) < 0 && rc == 0) rc = -errno;
    if (ioctl(fd, kIoctlGreen, g) < 0 && rc == 0) rc = -errno;
    if (ioctl(fd, kIoctlBlue, b) < 0 && rc == 0) rc = -errno;
    close(fd);
    return rc;
}

// All channels off. Returns 0 on success, -errno on failure.
inline int off() {
    int fd = open_device();
    if (fd < 0) return -errno;
    int rc = (ioctl(fd, kIoctlOff, 0) < 0) ? -errno : 0;
    close(fd);
    return rc;
}

}  // namespace led_ioctl
