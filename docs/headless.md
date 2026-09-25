# Headless management

Some boxes run Kiosk Satellite without showing it: a projector, a media box, anything whose screen belongs to another app. Usually these run in agent mode (**Settings**, **Device**, **Agent mode**), which drops the dashboard, voice and cameras but keeps the device in Home Assistant, the remote admin and the fleet. The settings below, under **Settings**, **Device**, **Headless**, make such a box manageable from Home Assistant. Each is off until turned on, and each belongs to one device (fleet sync never copies it).

Several of these rest on the Kiosk Satellite accessibility service (see [Remote keys](gestures.md#remote-keys) for enabling it). On firmware that turns it off again, grant `WRITE_SECURE_SETTINGS` once over adb and Kiosk Satellite keeps it on by itself:

```
adb shell pm grant me.jxl.kiosk_satellite android.permission.WRITE_SECURE_SETTINGS
```

## Remote keys in Home Assistant

**Send remote keys to Home Assistant** adds an event entity, **Remote key**, that fires for each key pressed on the remote, whatever app is in front. Its event types are the keys a remote has that are not text: `home`, `back`, `menu`, the D-pad (`dpad_up` … `dpad_center`), the media keys, volume, `red`/`green`/`yellow`/`blue`, `f1`–`f12`, `settings`, `tv_input`, `info`, `guide` and a few more. Letters, digits and symbols are never reported, so a keyboard typing into an app is never sent anywhere. Reporting only observes: the key still does what it did.

```yaml
triggers:
  - trigger: state
    entity_id: event.projector_remote_key
    attribute: event_type
    to: red
actions:
  - action: light.toggle
    target:
      entity_id: light.theater
```

A key the device's firmware keeps for itself never reaches Kiosk Satellite, so it cannot be reported either (see [Remote keys](gestures.md#remote-keys)).

## Now playing

**Report what is playing** publishes whatever another app plays - Plex, Plezy, Kodi, YouTube - as **Media state** (`playing`, `paused`, `buffering`, `stopped`, `idle`), **Media app**, **Media title** and **Media artist**, with **Media play/pause**, **Media next**, **Media previous** and **Media stop** buttons and a `media_control` action (`play`, `pause`, `play_pause`, `next`, `previous`, `stop`).

Android shows other apps' playback only to an app with notification access. Kiosk Satellite reads no notifications; the listener exists only to unlock the media sessions. With `WRITE_SECURE_SETTINGS` granted it turns notification access on by itself while this switch is on, and takes it back when the switch goes off (only if it was the one that granted it). Without the grant, allow it once in Android's **Notification access** settings.

## Sending keys

The `send_key` action presses a key on the device from Home Assistant, with no root or ADB:

| Keys | How | Works on |
| --- | --- | --- |
| `play_pause`, `play`, `pause`, `stop`, `next`, `previous`, `rewind`, `fast_forward` | Sent to the app that owns the active media session | Every Android |
| `volume_up`, `volume_down`, `volume_mute` | The audio service, with the volume panel shown | Every Android |
| `back`, `home`, `recents`, `notifications` | Accessibility global actions | Every Android, with the accessibility service on |
| `dpad_up`, `dpad_down`, `dpad_left`, `dpad_right`, `dpad_center` | Accessibility global actions | Android 13 and newer |

An app cannot inject other keys (that needs a system permission), so anything else fails with the reason, which the action returns.

## The home app

**Home app** names the app this box should normally show, such as `com.spocky.projengmenu`. **Open the home app at boot** starts it once the device has booted. **Return to the home app when idle** brings it back after that many minutes with no remote key pressed and nothing playing - the vendor launcher, a crashed player or a forgotten settings screen gets replaced by the app the box is for. It never interrupts playback. The app in front comes from the accessibility service's window events, so no Usage access is needed.

## Daily restart

**Daily restart** restarts the device every day at the time given (24-hour `HH:MM`). Android lets an app restart the device only as the device owner or through a granted Shizuku connection, the same condition as the **Restart device** button; elsewhere the restart is refused and logged. It never runs within ten minutes of a boot.

## Health

- **Running hot** turns on while the CPU is hotter than **Running hot above** (85 °C by default), on devices that report a CPU temperature.
- On an agent, **Self repairs** counts what Kiosk Satellite put back after firmware took it away (the accessibility service, notification access), and **Last self repair** says what and when - so a vendor that keeps doing it shows up in history instead of being fixed silently.

## Installed apps

The remote admin's **App Launcher** page lists every app the device can launch, with its version and when it was last updated, and opens any of them. **Uninstall** opens Android's own confirmation on the device: nothing is removed from the admin alone.
