import { api, state } from './core.js';

const groups = () => document.querySelectorAll('.nav-group');

/**
 * Rolled-up sidebar groups, the remote half of the device's rail roll-up.
 *
 * Both surfaces read and write the same `ui.collapsed_groups` setting, so a
 * group folded here is folded on the panel's own screen too: it is the
 * panel's preference, and Remote Admin is a view of that panel rather than a
 * second place to keep the same answer.
 *
 * The device rail builds itself from the settings definitions; this sidebar
 * is hand-written markup in index.html. What ties them together is the
 * heading text, which is why the stored list holds headings rather than
 * anything structural.
 */

const KEY = 'ui.collapsed_groups';

/** Headings currently rolled up, from the settings the app already loaded. */
function collapsed() {
  const raw = (state.settings || []).find((s) => s.key === KEY)?.value;
  try {
    const parsed = JSON.parse(raw ?? '[]');
    if (Array.isArray(parsed)) return new Set(parsed.filter((h) => typeof h === 'string'));
  } catch (_) { /* a mangled value reads as nothing rolled up */ }
  return new Set();
}

/** Write the list back, keeping `state.settings` in step for the next read. */
async function store(headings) {
  const value = JSON.stringify([...headings].sort());
  const cached = (state.settings || []).find((s) => s.key === KEY);
  if (cached) cached.value = value;
  else (state.settings ||= []).push({ key: KEY, value });
  await api('/api/settings', {
    method: 'PATCH',
    body: JSON.stringify({ [KEY]: value }),
  });
}

/** Paint every group to match the stored list. */
function paint() {
  const folded = collapsed();
  for (const group of groups()) {
    const head = group.querySelector('.nav-head');
    if (!head) continue;
    const on = folded.has(head.textContent.trim());
    group.classList.toggle('collapsed', on);
    head.setAttribute('aria-expanded', String(!on));
  }
}

/**
 * Wire the headings once. Called after the settings load, and again whenever
 * they are refreshed, so a roll-up done on the panel shows up here.
 */
export function initNavGroups() {
  for (const group of groups()) {
    const head = group.querySelector('.nav-head');
    if (!head || head.dataset.rollup === '1') continue;
    head.dataset.rollup = '1';
    head.setAttribute('role', 'button');
    head.setAttribute('tabindex', '0');

    const toggle = async () => {
      const heading = head.textContent.trim();
      const folded = collapsed();
      if (!folded.delete(heading)) folded.add(heading);
      // Paint first: the sidebar answers the tap immediately, and the write
      // is a round trip to a panel that may be on the far end of poor wifi.
      group.classList.toggle('collapsed');
      head.setAttribute('aria-expanded', String(!group.classList.contains('collapsed')));
      try {
        await store(folded);
      } catch (_) {
        paint();  // The device refused or is unreachable: show the truth.
      }
    };

    head.addEventListener('click', toggle);
    head.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); }
    });
  }
  paint();
}

export { paint as paintNavGroups };
