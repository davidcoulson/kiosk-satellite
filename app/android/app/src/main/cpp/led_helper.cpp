// Standalone CLI over the /dev/ledjni ioctl protocol in led_ioctl.h, for the
// rooted fallback path (LedBridge.kt): on a panel where a normal app
// process can't open the node directly (SELinux-denied to the app domain,
// per ha-paneld's own findings on some rk3576 panels), this binary is
// invoked through `su -c` instead, which typically runs unconfined and can
// still reach the node. Short-lived per call - LED writes are infrequent
// enough that a persistent root daemon isn't worth the extra moving part.
//
// Usage:
//   led_helper probe            -> exit 0 if the node opens, else 1
//   led_helper setrgb R G B     -> exit 0 on success, else prints -errno
//   led_helper off               -> exit 0 on success, else prints -errno

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "led_ioctl.h"

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: led_helper probe|setrgb R G B|off\n");
        return 2;
    }

    if (std::strcmp(argv[1], "probe") == 0) {
        return led_ioctl::probe() ? 0 : 1;
    }

    if (std::strcmp(argv[1], "off") == 0) {
        int rc = led_ioctl::off();
        if (rc != 0) std::printf("%d\n", rc);
        return rc == 0 ? 0 : 1;
    }

    if (std::strcmp(argv[1], "setrgb") == 0 && argc == 5) {
        int r = std::atoi(argv[2]);
        int g = std::atoi(argv[3]);
        int b = std::atoi(argv[4]);
        int rc = led_ioctl::set_rgb(r, g, b);
        if (rc != 0) std::printf("%d\n", rc);
        return rc == 0 ? 0 : 1;
    }

    std::fprintf(stderr, "usage: led_helper probe|setrgb R G B|off\n");
    return 2;
}
