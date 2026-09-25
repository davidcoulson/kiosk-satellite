import { launcherText } from './localization.js';
import { cameraAction, cameraListRow } from './cameras.js';
import { cmd } from './core.js';
import { messageBox } from './widgets.js';

/* ---- Installed apps (headless management) ----
   Every app the device can launch, with its version and when it was last
   updated, so a projector's players can be checked and opened without
   walking over to it. Uninstall opens Android's own confirmation on the
   device: nothing is removed from here alone. Appended to the App
   Launcher page, which an agent keeps. */

let showSystem = false;

function day(ms) {
  if (!ms) return '';
  const d = new Date(Number(ms));
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}

export async function loadInstalledApps() {
  const tab = document.getElementById('tab-launcher');
  if (!tab) return;
  let root = document.getElementById('installed-apps');
  if (!root) {
    root = document.createElement('div');
    root.id = 'installed-apps';
    tab.appendChild(root);
  }
  const result = await cmd('listInstalledApps').catch(() => null);
  const apps = result?.ok && Array.isArray(result.data) ? result.data : [];
  root.innerHTML = '';

  const heading = document.createElement('h2');
  heading.className = 'card-title';
  heading.textContent = launcherText('Installed apps');
  root.appendChild(heading);
  const card = document.createElement('div');
  card.className = 'card';
  root.appendChild(card);

  const toggle = document.createElement('label');
  toggle.className = 'desc';
  toggle.style.cssText = 'display:flex; gap:8px; align-items:center; padding:10px 16px;';
  const box = document.createElement('input');
  box.type = 'checkbox';
  box.checked = showSystem;
  box.addEventListener('change', () => { showSystem = box.checked; loadInstalledApps(); });
  toggle.append(box, document.createTextNode(launcherText('Show system apps')));
  card.appendChild(toggle);

  const shown = apps.filter((a) => showSystem || !a.system);
  if (!shown.length) {
    card.appendChild(cameraListRow(launcherText('No apps to show'), '', []));
  }
  for (const app of shown) {
    const bits = [app.package];
    if (app.version) bits.push(`v${app.version}`);
    if (app.updated) bits.push(`${launcherText('updated')} ${day(app.updated)}`);
    const actions = [
      cameraAction(launcherText('Open'), async () => {
        const r = await cmd('launchApp', { package: app.package }).catch(() => null);
        if (!r?.ok) {
          await messageBox({ title: app.label, message: r?.error || launcherText('Could not open it.') });
        }
      }),
    ];
    if (!app.system && !app.self) {
      actions.push(cameraAction(launcherText('Uninstall'), async () => {
        const choice = await messageBox({
          title: app.label,
          message: launcherText('Android asks to confirm on the device itself. Continue?'),
          buttons: ['Cancel', 'Uninstall'],
        });
        if (choice !== 'Uninstall') return;
        const r = await cmd('uninstallApp', { package: app.package }).catch(() => null);
        if (!r?.ok) {
          await messageBox({ title: app.label, message: r?.error || launcherText('Could not start the uninstall.') });
        }
      }, false, 'delete'));
    }
    card.appendChild(cameraListRow(app.label, bits.join(' · '), actions, { icon: 'apps' }));
  }
}
