# Dragon Touch "Classic 21" (joyhong) picture frame

Notes from running Kiosk Satellite on the Dragon Touch 21.5" WiFi frame (Allwinner A133, Android 10, eng/test-keys build). Two frames, same firmware.

## Hardware and firmware

- 1080x1920 native portrait panel, ~2 GB RAM, remote only (no touch), speaker, no mic, no camera, light sensor and accelerometer.
- **32-bit userspace** (zygote32): build with `flutter build apk --release --target-platform android-arm` and check `unzip -l app-release.apk | grep libflutter.so` shows `armeabi-v7a`.
- adb is open on port 5555 as root with no authentication (`ro.secure=0`). Anyone on the LAN has root, so keep the frame on a trusted VLAN.
- `/system`, `/vendor`, `/product` are overlayfs; run `mount -o remount,rw <part>` before writing and the change persists. The remount does not survive a reboot.

## 1. Current WebView

The stock WebView is too old. Google WebView 156 (min API 29) installs but is not a selectable provider, because the framework whitelist (`config_webview_packages`) only lists the vendor one. Fix with a static runtime resource overlay in `/product/overlay/WebViewGoogle/WebViewGoogle.apk` (package `local.webview.googleprovider`, `isStatic`, priority 99, SELinux label `vendor_overlay_file`) whose `res/xml/config_webview_packages.xml` adds `com.google.android.webview`. The build is debuggable, so no `<signature>` element is needed. Rollback: `rm -rf /product/overlay/WebViewGoogle` and reboot.

## 2. Vendor watchdog

The patched `com.android.settings` relaunches `com.waophoto.smartframe` about 11 s after any other app takes the foreground (logcat tag `POOOOOOOO: pckName ====`). Disable the vendor app so Kiosk Satellite can stay up: `pm disable-user com.waophoto.smartframe` (re-enable with `pm enable`). Check afterwards with `pm list packages -d`; the state did not persist when the frame was rebooted straight after the command.

## 3. Boot into Kiosk Satellite

Turn on *Act as the home screen* (Home Launcher feature). With the vendor app disabled the frame boots straight into Kiosk Satellite.

## 4. Screen boots sideways

`DisplayRotation.rotationForOrientation` in the patched `services.jar` returns a fixed ROTATION_90 until the system property `service.tbootanim.exit` is `1`. Nothing sets it once the vendor app is disabled, so `user_rotation`, `accelerometer_rotation` and Kiosk Satellite's `screen.orientation` have no effect. Set it after boot from an init script (`on boot` is too early, the property is reset afterwards):

```
# /vendor/etc/init/ks-rotation.rc   (label u:object_r:vendor_configs_file:s0)
on property:sys.boot_completed=1
    setprop service.tbootanim.exit 1
```

Then lock the rotation with `settings put system accelerometer_rotation 0` and `settings put system user_rotation <0|2>`, leaving Kiosk Satellite's orientation on `auto`. On these frames `user_rotation 2` is the right way up when hung with the remote end down; use `0` if yours is upside down. Kiosk Satellite's `reverse_portrait` is ignored by this window manager.

## 5. Photos from the SD/USB card

Kiosk Satellite lists the Local Media folder with plain file reads, so granting `READ_EXTERNAL_STORAGE` is enough on Android 10. The card mounts as `/storage/<volume-id>`, which differs per frame. A symlink gives every frame the same path: `ln -s /storage/<id> /product/photos` (with `/product` remounted rw), then set the Local Media folder to `/product/photos`. Mac-created `._*` files on the card should be deleted: `find /storage/<id> -name '._*' -delete`.

## 6. Permissions on a remote-only frame

Display over other apps and unrestricted battery can be granted through the Overview *Grant on device* buttons, or with adb (`appops set me.jxl.kiosk_satellite SYSTEM_ALERT_WINDOW allow`, `dumpsys deviceidle whitelist +me.jxl.kiosk_satellite`). `MANAGE_EXTERNAL_STORAGE` does not exist on Android 10.
