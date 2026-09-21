# Onboarding a new panel

How a new tablet becomes a managed panel in this house: rooted, stripped of
what it shipped with, running Kiosk Satellite with the same profile as the
office panels, and visible in Home Assistant.

`tool/onboard-panel.sh` does the parts that can be done over ADB. The parts
before that are physical and are described here. Read [Where scripting
stops](#where-scripting-stops) before planning an evening around this.

The end state, per the office panels:

| | |
| --- | --- |
| Rooted | Magisk, so the Device Performance and LED plugins work and system apps can be hidden |
| Debloated | vendor apps removed for user 0; anything protected hidden with a Magisk module |
| Manageable | ADB over TCP on 5555, a DHCP reservation, remote admin on 2324 |
| Configured | the house profile cloned from an existing panel, with its own name and dashboard |
| Visible | ESPHome device and Bluetooth proxy in Home Assistant, its own Voice Satellite entity |

## Where scripting stops

Three things cannot be scripted from the laptop, because they happen before
ADB exists or because they are specific to the hardware in your hands.

**Unlocking the bootloader.** Physical, and it wipes the device — so do it
first, before any configuration. The steps differ by vendor: on the Rockchip
panels it means loader/maskrom mode with a button combo and `rkdeveloptool`
or the vendor's Windows tool, not `fastboot oem unlock`. Some panels ship
unlockable; some never do. If the bootloader will not unlock, the device can
still run Kiosk Satellite — it just cannot be rooted, so skip to
[Debloat](#3-debloat) and expect the root-only plugins to stay off.

**Rooting with Magisk.** The patched image has to come from *this device's
own* firmware: pull or download its `boot.img`, patch it in the Magisk app
on the device, copy it back, flash it. A patched image from another panel
will brick this one, even from the same model with different firmware.

**First boot.** Joining Wi-Fi, skipping the Google account, and turning on
Developer options and USB debugging are taps on the screen. Join the IoT
VLAN here, not the trusted LAN.

Everything after that is the script.

## 1. Prepare

- Bootloader unlocked, Magisk installed, device booted and on Wi-Fi.
- USB cable to the laptop, USB debugging authorised for this machine.
- The APK built for arm64:
  `cd app && flutter build apk --release --target-platform android-arm64`.
  Every panel here is arm64, and this build is about 90 MB against the
  universal APK's 189 — the rest is 32-bit ARM and x86_64 code no panel can
  run, which matters over a panel's Wi-Fi. A 32-bit-only device would need
  the universal build instead; `install` warns when an APK carries ABIs the
  device cannot use.
- An existing panel to copy from, reachable, and the admin password in
  `~/Desktop/ks-remote-pw.txt` or `KS_REMOTE_PW`.

```bash
./tool/onboard-panel.sh preflight
```

Prints the model, Android version, ABIs, IP and whether root works. If it
says root is missing and you expected it, stop and fix that first: rooting
later means unlocking, which wipes everything you are about to configure.

## 2. Reserve its address

Give the panel a DHCP reservation on the IoT VLAN before going further. Its
address ends up in a Magisk module, in Home Assistant, and in your own
muscle memory; letting it move later is a bad afternoon.

## 3. Debloat

```bash
./tool/onboard-panel.sh debloat-scan     # writes ./debloat-candidates.txt
$EDITOR debloat-candidates.txt           # remove anything worth keeping
./tool/onboard-panel.sh debloat --apply
```

The scan lists every package that is not Android's own, the app, or Magisk.
It proposes; it never removes on its own, because which vendor package
matters is a judgement about this hardware and a wrong guess is a panel that
does not boot.

Keep, unless something else provides them:

- a launcher and an input method — without a keyboard there is no way to type
  a Wi-Fi password on the device itself
- anything you actually use (BubbleUPnP is in the list on the office panels
  and is wanted there)
- `com.topjohnwu.magisk`

Removal is `pm uninstall -k --user 0`: the APK stays in the system image, so
`cmd package install-existing <pkg>` brings it back, and a factory reset
restores everything.

**Packages that will not go.** A `PERSISTENT` system app keeps running even
after `pm disable-user` — `.129` shipped with `com.elclcd.commonkeepalive`,
whose `ThirdAlivePullUpService` tries once a minute to pull a vendor app over
whatever is on screen. Hide it with a Magisk module instead:

```bash
mkdir -p no_vendorapp/system/app/<AppDirName>
touch no_vendorapp/system/app/<AppDirName>/.replace
cat > no_vendorapp/module.prop <<'EOF'
id=no_vendorapp
name=Remove <AppDirName>
version=v1.0
versionCode=1
author=david
description=Hides /system/app/<AppDirName>.
EOF
(cd no_vendorapp && zip -qr ../no_vendorapp.zip .)
adb push no_vendorapp.zip /data/local/tmp/
adb shell su -c "magisk --install-module /data/local/tmp/no_vendorapp.zip"
adb reboot
```

The `.replace` marker mounts an empty directory over that path, so the
package manager stops seeing it. The real partition is untouched — deleting
the module undoes it. Do not remount `/system` writable to delete such an
app: on Android 12 and later that partition is dm-verity-protected inside
`super`, and writing to it risks the boot.

## 4. ADB over TCP

```bash
./tool/onboard-panel.sh tcpip
adb connect <ip>:5555
```

From here the USB cable is optional. Port 5555 is reachable only from the
trusted LAN (10.2.3.0/24); every other VLAN is blocked at the firewall.
There is no authentication on ADB, so that firewall rule is the only thing
protecting root on this panel.

## 5. Install Kiosk Satellite

```bash
./tool/onboard-panel.sh install --apk app/build/app/outputs/flutter-apk/app-release.apk
adb -s <ip>:5555 shell monkey -p me.jxl.kiosk_satellite -c android.intent.category.LAUNCHER 1
```

Installs and grants everything `docs/permissions.md` lists, choosing the
right set for the Android version: runtime permissions, display-over-other-apps,
modify-system-settings, all-files, usage access, the battery exemption, device
admin and the accessibility guard. It refuses to clobber an existing
accessibility service and says so instead.

Launch the app once before provisioning, so its settings store exists.

## 6. Provision

```bash
./tool/onboard-panel.sh provision --from 10.2.4.145 \
  --name 'Kitchen Panel' \
  --dashboard https://home-iot.coulson.io/kitchen/main
```

What happens, in order:

1. A provisioning intent turns on the remote admin and sets its password.
   This is the only step that uses an intent; everything after it is HTTP.
2. The source panel's full config is fetched and imported with
   `adoptIdentity=0`, which sheds the things two panels must not share: the
   device name, hostname, ESPHome node name, Sendspin player id, fleet
   membership and Voice Satellite entity.
3. The new panel's own identity is set: name, hostname, dashboard URL and
   Voice Satellite entity, with the ESPHome node name left empty so the next
   start derives it from the device name.

What the clone carries, deliberately: the Home Assistant URL and token, the
Bluetooth proxy key and advertisement filter, the injected dashboard JS,
screen and brightness settings, the ESPHome entity selection, and the admin
password (as its hash — the import stores it as it stands). The office panels
share the Bluetooth proxy key, so the new one will too; give it its own from
the ESPHome page if you would rather they differ.

Then restart and check:

```bash
./tool/onboard-panel.sh verify --restart
```

The restart is the point: on first run the secrets are still as typed, and
only the *second* start proves they can be read back out of the Keystore.
`verify` checks the version, that the password still logs in and a wrong one
is refused, that secrets are wrapped on disk, that Home Assistant is
connected, that the ESPHome session and Bluetooth scan are alive, and that
nothing complained about the secret store.

## 7. Home Assistant

- **ESPHome** offers the new node for adoption once it announces itself.
  Its encryption key came across with the profile.
- **Voice Satellite**: create or rename the `assist_satellite` entity to
  match what was set, or pass `--satellite` to match one that exists.
- **Bluetooth proxy**: check it appears as a proxy and is reporting. The
  advertisement filter came from the source panel — reconsider its RSSI
  threshold for a room of a different size.
- **Dashboard**: the URL given at provisioning. The office panels use a
  dashboard per panel rather than one shared view.

## 8. Plugins

Six plugins run on the office panels, all installed from GitHub in
**Plugin Manager > Add plugin**, each needing **Trust and install**:

| Plugin | Notes |
| --- | --- |
| `device-performance` | CPU/GPU governors, diagnostics. Needs root |
| `network-adb` | reports ADB-over-TCP state |
| `network-diagnostics` | link and throughput sensors |
| `package-management` | inspect and manage packages from the admin UI |
| `rockchip-led-control` | front LED. Rockchip panels only |
| `stripper-plugin` | HA WebSocket stripper integration |

Plugin installs are not scripted: each one is a trust decision about code
that runs with the app's privileges, and some with root.

## Rolling back

- A package removed in step 3: `cmd package install-existing <pkg>`.
- A Magisk module: delete `/data/adb/modules/<id>` and reboot.
- A bad provisioning run: take a config export from the panel first
  (`GET /api/config/export`), and restore it the same way. Those exports hold
  secrets in the clear — delete them when finished.
- Downgrading the app below `2026.9.62-djc-2026.09.18.04` is not supported on
  a provisioned panel: older builds cannot read a wrapped secret and will
  compare a typed password against a stored hash. Restore a config export
  taken before the downgrade.

## When it is not rooted

Everything except step 3's Magisk module works without root. What is lost:
the root-only plugins, hiding protected vendor apps, and `verify`'s check
that secrets are wrapped on disk (it reads the preferences file as root). The
app itself, its Keystore-wrapped secrets, Home Assistant and the Bluetooth
proxy do not need root.
