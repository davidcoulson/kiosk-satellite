# Theater Mode

Theater mode is for a panel in a dark room: a home theater, a bedroom. It takes the panel darker than its backlight can go on its own, keeps people moving in the room from lighting it up, brings it up to readable with one touch, and puts everything back exactly as it was afterwards.

It is made to pair with a page like the theater panel's Showtime screen, which turns it on when a film starts and off when it ends, but Home Assistant, the remote admin and a dashboard link can all drive it too.

## What it does

Theater mode is either off, or on in one of three phases.

| Phase | Backlight | Over the page | A touch |
| --- | --- | --- | --- |
| **Dimmed** | The theater backlight, 0 by default: the lowest the panel can go | A black layer at the Dimming setting | The first touch only wakes the panel (see below) and starts a peek |
| **Peek** | The brightness when touched | Nothing | Reaches the page as usual, and keeps the peek going |
| **Black** | The panel minimum | Solid black | Wakes the panel and starts a peek; it never reaches the page |

A **peek** lasts a few seconds after the last touch, then the panel dims again. An alert, such as an announcement or a doorbell camera, peeks for as long as it shows and a few seconds after.

**The first touch in the dark presses nothing.** A finger landing on Stop in a dimmed room wakes the panel and the page never sees it: not a tap, not the start of a scroll. The next touch works normally. Turn off **First touch only wakes the screen** to pass the first touch through as well.

**Black** comes after a long spell with no touch, if **Go black after** is set. The screen stays on and the page keeps rendering, so the next peek shows a current page rather than a stale one.

### It always comes back

Theater mode is never stored. A crash, a force stop, an app update or a reboot always comes back with it off and the panel at its normal brightness, and the Home Assistant switch shows off. Whatever turned it on can turn it on again.

It never writes the brightness settings either. The dimming is a hold over the panel for as long as theater mode lasts. Moving the Screen light, the brightness slider or adaptive brightness during a film changes the stored level as usual, and that level is what the panel shows when theater mode ends. With nothing changed, the panel returns to exactly the brightness it had before.

A safety cap, **Turn off after**, ends theater mode after six hours however it was turned on, so a lost "off" never leaves a panel dark for days.

Theater mode also turns itself off if the main page moves to another site, one that is neither the start page nor Home Assistant. Reloading the page or changing its `#` route keeps it on.

## While it is on

| | |
| --- | --- |
| **Screensaver** | Never starts, and one showing stops. When theater mode ends, its idle timer starts again from zero, so it does not start the moment the lights come up. |
| **Adaptive brightness** | Held. The light sensor still reads and still reports to Home Assistant, and the room's level applies when theater mode ends. |
| **Screen light, brightness slider** | Change the stored level, which shows when theater mode ends. The Screen light reports the brightness really on the panel. Turning the Screen light off still turns the screen off. |
| **Screen off and on** | Screen off works, and theater mode stays on. Screen on comes back dimmed, not at full brightness. |
| **Motion, face, proximity, person** | Do not brighten the panel, with **Ignore people moving** on. Home Assistant still sees them, so its automations still run. |
| **Announcements, notifications, camera views, voice turns, the intercom** | Peek while they show, with **Brighten for alerts** on. Media playback is not an alert, since it would hold the panel bright for a whole film. |
| **Wake word** | Unchanged, unless **Mute the wake word** is on: then it stops for theater mode and comes back when it ends. |
| **Lockdown** | Draws above theater mode and still owns every touch. Ending theater mode never changes Lockdown. |
| **View rotation, return to the dashboard** | Wait, and resume when theater mode ends. |

## Settings

Under **Settings > Screen & Audio > Theater mode**, and the same section in the remote admin. A caller turning theater mode on may override the first five for that time only.

| Setting | Default | What it does |
| --- | --- | --- |
| Backlight while dimmed | 0% | Screen brightness in theater mode. 0 is the lowest the panel can go; the dimming layer takes it darker still. |
| Dimming | 60% | How much the black layer darkens the page, below what the backlight can do on its own. Up to 95%. |
| Brightness when touched | 30% | Screen brightness while peeking. |
| Stay bright for | 8 s | How long a peek lasts after the last touch. 3 to 60 seconds. |
| Go black after | 0 (never) | Turn the dimmed panel fully black after this long without a touch. |
| First touch only wakes the screen | On | While dimmed, the first touch brightens the panel and is not passed to the page. |
| Ignore people moving | On | Motion, face, proximity and person detection do not brighten the panel. |
| Brighten for alerts | On | Announcements, notifications, camera views, voice turns and the intercom peek while they show. |
| Mute the wake word | Off | Stop listening for the wake word in theater mode. |
| Turn off after | 6 h | The safety cap. |
| Page allowed from a frame | empty | A page in a frame on a Home Assistant dashboard that may use theater mode. See [A page in a frame](#a-page-in-a-frame). |

## Turning it on

### From Home Assistant

Theater mode appears on the ESPHome device with the other kiosk entities (see [ESPHome](esphome.md)):

| Entity | Type | What it does |
| --- | --- | --- |
| **Theater mode** | switch | On and off. Off whenever the app starts. |
| **Theater phase** | text sensor (diagnostic) | `off`, `dim`, `peek` or `black`. |
| **Theater peek** | button | One peek. |
| **Theater dimming** | number (config) | The Dimming setting, 0 to 95%. |
| **Theater peek time** | number (config) | The Stay bright for setting, 3 to 60 s. |

The `esphome.<node name>_set_theater_mode` action turns it on or off with its levels for that time: `active`, `overlay_opacity` and `backlight`, where -1 means "the setting".

This automation turns theater mode on a couple of seconds into playback and off twenty seconds after it stops, whatever page the panel is showing:

```yaml
triggers:
  - trigger: state
    entity_id: media_player.home_theater
    to: playing
    for: "00:00:02"
    id: "on"
  - trigger: state
    entity_id: media_player.home_theater
    to: [idle, standby, "off"]
    for: "00:00:20"
    id: "off"
actions:
  - action: "switch.turn_{{ trigger.id }}"
    target: { entity_id: switch.ks_theater_panel_theater_mode }  # your node's switch
```

To send the panel to a page as well, `esphome.<node name>_navigate` moves the main page. A `#` route on the page already showing changes in place with no reload:

```yaml
- action: esphome.ks_theater_panel_navigate
  data:
    url: "#/showtime"
```

### From the page

The start page, or a Home Assistant page, can use theater mode through the [JavaScript API](js-api.md#theater-mode): `setTheaterMode(active, options)`, `getTheaterMode()` and `theaterPeek(seconds)`, with a `kiosksatellite:theatermode` event on every change. Other sites, and frames inside a page, cannot.

```js
const ks = window.kioskSatellite;
if (ks?.setTheaterMode) {
  await ks.setTheaterMode(true, { overlayOpacity: 0.6, peekSeconds: 8 });
  window.addEventListener('kiosksatellite:theatermode', (e) => render(e.detail.phase));
}
```

The event is sent again after every page load, so a page that reloads in the middle of a film picks up the current phase straight away.

### From a page in a frame

A page shown inside a Home Assistant dashboard, rather than as the whole page, cannot reach `window.kioskSatellite`, but it can ask the dashboard around it. See [A page in a frame](#a-page-in-a-frame).

### From a dashboard link

`ks://theater` toggles it; `ks://theater/on`, `ks://theater/off` and `ks://theater/peek` do what they say. See [Dashboard Links](dashboard-links.md).

### From the remote API

`setTheaterMode`, `getTheaterMode`, `theaterPeek` and `navigate` are ordinary commands. See [Remote API](remote-api.md).

## A page in a frame

Voice Satellite runs inside Home Assistant's own page, so a panel whose start page is some other web app has no wake word and no satellite. To keep both, show the web app inside Home Assistant instead: make a **Webpage** dashboard in Home Assistant with the app's address, make that dashboard the panel's start page, and turn on HA kiosk mode to hide Home Assistant's header and sidebar. Voice Satellite then runs in the dashboard as usual, with the app filling the screen inside it.

The app is in a frame there, and frames never get the page bridge, since a frame with it could open the microphone. Instead, put the app's address in **Page allowed from a frame** under **Settings > Screen & Audio > Theater mode**. The dashboard then passes theater mode calls from a frame at exactly that address (the same scheme, host and port) to the app, and nothing else: not the microphone, not brightness, not a frame that page embeds.

The framed page talks to the dashboard with `postMessage`:

```js
function theater(method, params) {
  return new Promise((resolve) => {
    const id = Math.random().toString(36).slice(2);
    const done = (result) => { removeEventListener('message', onReply); resolve(result); };
    const onReply = (e) => {
      if (e.source === window.parent && e.data?.ksTheater === 1 && e.data.id === id) done(e.data.result);
    };
    addEventListener('message', onReply);
    window.parent.postMessage({ ksTheater: 1, id, method, params }, '*');
    setTimeout(() => done(null), 3000);   // not on a kiosk, or not allowed
  });
}

await theater('setTheaterMode', { active: true, overlayOpacity: 0.6, peekSeconds: 8 });
await theater('getTheaterMode', {});
await theater('theaterPeek', { seconds: 10 });

addEventListener('message', (e) => {
  if (e.source === window.parent && e.data?.ksTheater === 1 && e.data.event === 'theatermode') {
    render(e.data.detail.phase);        // {active, phase, source}
  }
});
```

Replies carry what the page bridge method would return, or `null` when the call was refused. Theater mode events reach the frame once the app has accepted a call from it, so call `getTheaterMode` when the page loads.

With the app in a frame, `navigate` moves the Home Assistant page around it, not the app. Send the app to a route through the app itself.

## A custom start page

The theater panel runs its own web app rather than a Home Assistant dashboard. Under **Settings > Home Assistant > Dashboard**, choose **Custom URL** under **Start page** and enter its address, `http://` or `https://`. **Open now** loads it. The dashboard picker is hidden while the start page is custom, and choosing **Home Assistant dashboard** again brings it back; the custom address is remembered.

A custom start page counts as the dashboard: Go to dashboard returns to it, it is not treated as an external page, and it may use theater mode and the brightness methods. It is **not** treated as Home Assistant: the app never hands it the Home Assistant session, which only Home Assistant's own pages get.

Once a custom start page exists, Home Assistant's **Default dashboard** select also offers **Start page**, so an automation can switch between Home Assistant dashboards and it.
