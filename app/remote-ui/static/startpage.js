// The Start page choice on the Home Assistant tab (URL-1): a Home Assistant
// dashboard, picked with the dashboard card below it, or a custom page such
// as the theater panel's own web app. The device's settings screen builds the
// same card (start_page_card.dart).
//
// A custom address is written to browser.custom_start_url; the device makes
// it the start URL. Nothing here writes browser.start_url, so one place keeps
// the two in step.
import { api } from './core.js';
import { haText } from './localization.js';
import { radioRow } from './views.js';

/** Why [text] cannot be a custom start page, or null when it can: an http or
 * https address with a host. Mirrors validateCustomStartUrl on the device,
 * which refuses the same things when a write arrives by another route. */
export function customStartUrlProblem(text) {
  const value = String(text ?? '').trim();
  if (!value) return 'Enter a full http:// or https:// address';
  let url;
  try { url = new URL(value); } catch { return 'Enter a full http:// or https:// address'; }
  if ((url.protocol !== 'http:' && url.protocol !== 'https:') || !url.hostname) {
    return 'Enter a full http:// or https:// address';
  }
  return null;
}

/** Draws the card into [root] and answers whether the start page is custom,
 * so the caller can leave the dashboard picker out. [reload] re-renders the
 * tab after a change. */
export function renderStartPage(root, byKey, reload) {
  const mode = byKey['browser.start_page']?.value === 'custom' ? 'custom' : 'ha';
  const card = document.createElement('div');
  card.className = 'card';
  card.dataset.startPage = mode;

  const title = document.createElement('div');
  title.style.cssText = 'font-weight:600; padding:12px 14px 2px';
  title.textContent = haText('Start page');
  const help = document.createElement('div');
  help.style.cssText = 'color:var(--muted); font-size:0.9em; padding:0 14px 8px';
  help.textContent = haText('The page this panel opens on launch and returns to on Go to dashboard.');
  card.append(title, help);

  const choose = async (next) => {
    if (next === mode) return;
    await api('/api/settings', { method: 'PATCH', body: JSON.stringify({ 'browser.start_page': next }) });
    await reload();
  };
  card.append(
    radioRow(haText('Home Assistant dashboard'), '', mode === 'ha', () => choose('ha')),
    radioRow(haText('Custom URL'), '', mode === 'custom', () => choose('custom')),
  );

  if (mode === 'custom') {
    const field = document.createElement('input');
    field.type = 'url';
    // As the rotation URL box on this tab is drawn.
    field.style.cssText = 'flex:1; background:var(--surface-2);'
      + 'border:1px solid var(--border); border-radius:var(--radius-sm);'
      + 'color:var(--text); padding:9px 12px; margin-right:8px';
    field.placeholder = 'http://';
    field.setAttribute('aria-label', haText('Custom page address'));
    field.value = byKey['browser.custom_start_url']?.value || byKey['browser.start_url']?.value || '';
    const error = document.createElement('div');
    error.style.cssText = 'color:var(--error-ink); font-size:0.9em; padding:4px 14px 10px';
    error.hidden = true;
    const save = async () => {
      const problem = customStartUrlProblem(field.value);
      error.hidden = !problem;
      error.textContent = problem ? haText(problem) : '';
      if (problem) return false;
      await api('/api/settings', {
        method: 'PATCH',
        body: JSON.stringify({ 'browser.custom_start_url': field.value.trim() }),
      });
      return true;
    };
    field.addEventListener('change', () => { save(); });
    const open = document.createElement('button');
    open.className = 'btn-ghost';
    open.textContent = haText('Open now');
    open.addEventListener('click', async () => {
      if (!await save()) return;
      await api('/api/commands/loadStartUrl', { method: 'POST', body: '{}' });
    });
    const row = document.createElement('div');
    row.className = 'row';
    row.style.paddingLeft = '14px';
    row.append(field, open);
    card.append(row, error);
  }
  root.appendChild(card);
  return mode === 'custom';
}
