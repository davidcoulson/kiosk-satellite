import { haText, t } from './localization.js';
import { cmd, state } from './core.js';
import { cameraAction, cameraListRow } from './cameras.js';
import { loadDashboards } from './dashboard_picker.js';
import { readOnlyRow } from './device.js';
import { settingRow } from './rows.js';
import { banner, modalShell } from './widgets.js';

/* ---- Custom Pages ----
   Home Assistant > Custom Pages, the device's CustomPagesCard: the Share
   Home Assistant connection switch, then the person's own HTML pages, in
   Home Assistant's /local/ or on another server, each with the name the
   dashboard pickers show. A row opens the editor, Add page opens it
   empty. The list repaints itself on the device's echo, so a change on
   the device or in another admin shows here without rebuilding the tab. */

export const CUSTOM_PAGES_DOCS_URL = 'https://kiosksatellite.com/docs/custom-pages/';

// mdi:application-brackets-outline, the icon every page wears in the pickers
// and the shape of the page's own entry row.
const PAGE_ICON = 'M9.5,8.5L11,10L8,13L11,16L9.5,17.5L5,13L9.5,8.5M14.5,17.5L13,16L16,13L13,10L14.5,8.5L19,13'
  + 'L14.5,17.5M21,2H3A2,2 0 0,0 1,4V20A2,2 0 0,0 3,22H21A2,2 0 0,0 23,20V4A2,2 0 0,0 21,2M21,2'
  + '0H3V6H21V20Z';

function storedPages() {
  const raw = (state.settings || []).find((s) => s.key === 'ha.custom_pages')?.value;
  try {
    const list = JSON.parse(raw || '[]');
    return Array.isArray(list)
      ? list.filter((p) => p && typeof p.name === 'string' && typeof p.path === 'string')
      : [];
  } catch (_) { return []; }
}

/* Why Save & Validate refused, the device's customPageError (see
   HomeAssistantManager.saveCustomPage for the codes). */
function pageError(code) {
  code = `${code || ''}`;
  if (code.startsWith('status:')) {
    return t('haCustomPageStatus', { code: code.slice('status:'.length) });
  }
  switch (code) {
    case 'name': return haText('Enter a name.');
    case 'path': return haText('Enter a path under /local/ or an http or https URL.');
    case 'duplicate': return haText('Another page already uses this path.');
    case 'not_found': return haText('Home Assistant has no file at this path.');
    case 'url_not_found': return haText('The server has no page at this URL.');
    case 'url_unreachable': return haText('Could not reach the server.');
    default:
      if (code.startsWith('url_status:')) {
        return t('haCustomPageUrlStatus', { code: code.slice('url_status:'.length) });
      }
      return haText('Could not reach Home Assistant.');
  }
}

function field(label, control, hint) {
  const wrap = document.createElement('label');
  wrap.className = 'form-field';
  const title = document.createElement('span');
  title.className = 'desc';
  title.textContent = label;
  control.classList.add('field');
  control.style.maxWidth = 'none';
  wrap.append(title, control);
  if (hint) {
    const note = document.createElement('span');
    note.className = 'desc';
    note.style.fontSize = '12.5px';
    note.textContent = hint;
    wrap.append(note);
  }
  return wrap;
}

/* Add a page or change `page`. Save & Validate asks Home Assistant for
   the page first: a 200 saves and closes, anything else says why and
   keeps the dialog open. */
export function openCustomPageEditor(page, onSaved) {
  let saving = false;
  const shell = modalShell({
    title: page ? haText('Edit custom page') : haText('Add custom page'),
    width: 480,
    onDismiss: () => { if (!saving) shell.close(); },
  });
  const form = document.createElement('form');
  form.className = 'modal-form';
  const name = document.createElement('input');
  name.type = 'text';
  name.value = page?.name || '';
  const path = document.createElement('input');
  path.type = 'text';
  path.spellcheck = false;
  path.autocapitalize = 'off';
  path.value = page?.path || '/local/';
  const issue = document.createElement('div');
  issue.setAttribute('role', 'alert');
  form.append(field(haText('Name'), name),
    field(haText('Path or URL'), path,
      haText('A file in the Home Assistant www folder, such as /local/dashboard.html, or the URL of a page on another server.')),
    issue);
  shell.body.append(form);
  const cancel = document.createElement('button');
  cancel.type = 'button';
  cancel.className = 'btn-text';
  cancel.textContent = haText('Cancel');
  cancel.addEventListener('click', () => shell.close());
  const save = document.createElement('button');
  save.type = 'button';
  save.className = 'btn-primary';
  save.textContent = haText('Save & Validate');
  save.addEventListener('click', () => form.requestSubmit());
  shell.foot.append(cancel, save);
  const controls = [cancel, save, name, path];
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (saving) return;
    saving = true;
    controls.forEach((c) => { c.disabled = true; });
    save.textContent = haText('Checking…');
    issue.replaceChildren();
    const params = { name: name.value, path: path.value };
    if (page) params.original = page.path;
    const r = await cmd('haSaveCustomPage', params, { timeoutMs: 20000 })
      .catch((e) => ({ ok: false, error: e?.message }));
    saving = false;
    controls.forEach((c) => { c.disabled = false; });
    save.textContent = haText('Save & Validate');
    if (r?.ok) {
      shell.close();
      onSaved?.();
      return;
    }
    issue.replaceChildren(banner(pageError(r?.error), { error: true }));
  });
  (page ? path : name).focus();
}

/* The page itself: the connection switch in a group of its own, then the
   Custom Pages group with the list card and the guide. */
export function renderCustomPagesPage(panel) {
  if (!panel) return;
  panel.replaceChildren();
  const share = (state.settings || []).find((s) => s.key === 'ha.custom_pages_socket');
  if (share) {
    const shareCard = document.createElement('div');
    shareCard.className = 'card';
    const row = settingRow(share);
    row.dataset.searchId = 'ha.custom_pages_socket';
    shareCard.appendChild(row);
    panel.appendChild(shareCard);
    const heading = document.createElement('h2');
    heading.className = 'card-title';
    heading.textContent = haText('Custom Pages');
    panel.appendChild(heading);
  }
  const card = document.createElement('div');
  card.className = 'card';
  card.dataset.searchId = 'x:custom_pages';
  const list = document.createElement('div');
  card.appendChild(list);
  let shown = '';
  const paint = () => {
    const pages = storedPages();
    shown = JSON.stringify(pages);
    list.replaceChildren();
    if (!pages.length) {
      const note = document.createElement('div');
      note.className = 'group-note';
      note.style.padding = '12px 0 4px';
      note.textContent = haText('Add HTML pages from the Home Assistant www folder or another server to pick them like a dashboard.');
      list.appendChild(note);
    }
    for (const page of pages) {
      const remove = cameraAction(haText('Remove'), async () => {
        await cmd('haRemoveCustomPage', { path: page.path });
        changed();
      }, false, 'delete');
      const row = cameraListRow(page.name, page.path, [remove], {
        onClick: () => openCustomPageEditor(page, changed),
      });
      row.querySelector('.desc')?.classList.add('mono');
      const icon = document.createElement('span');
      icon.className = 'camera-row-icon custom-page-icon';
      icon.innerHTML = `<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="${PAGE_ICON}"/></svg>`;
      row.querySelector('.camera-row-main')?.prepend(icon);
      list.appendChild(row);
    }
    // The rotation's Add views row, the device's primary add tile.
    const add = document.createElement('button');
    add.type = 'button';
    add.className = 'dp-add-row';
    add.textContent = haText('Add page');
    add.addEventListener('click', () => openCustomPageEditor(null, changed));
    list.appendChild(add);
  };
  // The pickers' cached list carries the pages, so it is read again too.
  const changed = () => { loadDashboards(); };
  paint();
  panel.appendChild(card);

  const docsCard = document.createElement('div');
  docsCard.className = 'card';
  const docs = readOnlyRow(haText('Custom page guide'),
    haText('How to build a page that talks to Home Assistant.'), '', false);
  docs.querySelector('span')?.remove();
  docs.dataset.searchId = 'x:custom_pages_docs';
  const link = document.createElement('a');
  link.className = 'btn-ghost';
  link.textContent = haText('Open guide');
  link.href = CUSTOM_PAGES_DOCS_URL;
  link.target = '_blank';
  link.rel = 'noreferrer';
  docs.appendChild(link);
  docsCard.appendChild(docs);
  panel.appendChild(docsCard);

  // The device's echo of a save or a change made elsewhere.
  const onSettings = (e) => {
    if (!card.isConnected) {
      document.removeEventListener('ks-settings', onSettings);
      return;
    }
    if (!(e.detail || []).includes('ha.custom_pages')) return;
    if (JSON.stringify(storedPages()) !== shown) paint();
  };
  document.addEventListener('ks-settings', onSettings);
}
