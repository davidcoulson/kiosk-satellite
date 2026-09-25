import { state } from './core.js';

/* ---- Agent mode in the admin ----------------------------------------
   An agent runs no browser, screensaver, voice engine, media player,
   camera or kiosk lock: those managers never start, and their commands do
   not exist on the device. Everything below is therefore not "hidden to
   reduce clutter" but removed because pressing it would fail and reading
   it would report the absence of something nobody asked for.

   One pass over the shell rather than a check scattered through every
   panel: the flag is known once the settings arrive, and what it changes
   is which controls exist. Nothing here disables a feature - flip the
   setting back and a reload brings the whole admin back, because the
   pages and tiles are only hidden.                                     */

export function isAgent() {
  return (state.settings || []).some(
    (s) => s.key === 'device.agent_mode' && s.value === true,
  );
}

// Pages whose subject an agent does not run. ESPHome, Screen & Audio and
// App Launcher are deliberately absent: the ESPHome device, the screen and
// opening another app are what an agent is for. Gestures stays for its
// remote keys, the one input a projector has; the page itself offers an
// agent only that trigger (gestures.js).
const HIDDEN_TABS = [
  'homeassistant', 'voicesatellite', 'screensaver', 'browser',
  'sendspin', 'dlna', 'intercom', 'camera', 'cameras',
  'kiosk', 'lockdown', 'home',
];

// Quick controls. A tile is named by its id where it has one, and by the
// command it sends where it does not.
const HIDDEN_TILE_IDS = [
  'tileScreensaver', 'tileCameraView', 'tileDnd', 'tileSnapshot', 'tileExitApp',
];
const HIDDEN_TILE_CMDS = ['reload', 'clearWebCache', 'postponeScreensaver'];

export function applyAgentTrim() {
  if (!isAgent()) return;
  document.body.classList.add('agent');

  // The header says which kind of kiosk this is, on the title line: just
  // before the connection dot on a wide screen, after the title on a phone.
  // The same word the switcher tags it with.
  const pill = () => {
    const el = document.createElement('span');
    el.className = 'agent-pill';
    el.textContent = 'Agent';
    el.title = 'Management agent: no dashboard, voice, screensaver or cameras';
    return el;
  };
  const title = document.querySelector('.brand-title');
  if (title && !title.querySelector('.agent-pill')) {
    title.insertBefore(pill(), document.getElementById('connDot'));
  }
  const mtitle = document.querySelector('.mobilebar .mtitle');
  if (mtitle && !mtitle.querySelector('.agent-pill')) mtitle.appendChild(pill());

  for (const tab of HIDDEN_TABS) {
    document.querySelector(`#sidebar [data-tab="${tab}"]`)?.classList.add('hidden');
  }
  // A group whose every page went with them: the heading would otherwise
  // sit over nothing.
  document.querySelectorAll('#sidebar .nav-group').forEach((group) => {
    const shown = [...group.querySelectorAll('button[data-tab]')]
      .some((b) => !b.classList.contains('hidden'));
    if (!shown) group.classList.add('hidden');
  });

  for (const id of HIDDEN_TILE_IDS) {
    document.getElementById(id)?.classList.add('hidden');
  }
  for (const cmd of HIDDEN_TILE_CMDS) {
    document.querySelector(`.tile[data-cmd="${cmd}"]`)?.classList.add('hidden');
  }
}
