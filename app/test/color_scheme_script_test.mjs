import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL(
  '../lib/managers/browser/color_scheme_script.dart', import.meta.url,
), 'utf8');
const template = source
  .match(/String colorSchemeJs\(\{required bool dark\}\) \{\s*return '''([\s\S]*?)''';/)[1]
  .replace(/\\\\/g, '\\');

// Runs the script with the dashboard at [dark] against a window whose own
// matchMedia records the queries that reach it.
function page(dark) {
  const native = [];
  const window = {
    matchMedia: (query) => {
      native.push(query);
      return { media: query, matches: false };
    },
  };
  runInNewContext(template.replace('$dark', String(dark)), {
    window,
    EventTarget,
    Event,
  });
  return { window, native };
}

test('the color scheme answers with the dashboard state', () => {
  const dark = page(true).window;
  assert.equal(dark.matchMedia('(prefers-color-scheme: dark)').matches, true);
  assert.equal(dark.matchMedia('(prefers-color-scheme: light)').matches, false);
  const light = page(false).window;
  assert.equal(light.matchMedia('(prefers-color-scheme: dark)').matches, false);
  assert.equal(light.matchMedia('(prefers-color-scheme:light)').matches, true);
});

test('other queries reach the real matchMedia', () => {
  const { window, native } = page(true);
  const list = window.matchMedia('(max-width: 600px)');
  assert.equal(list.media, '(max-width: 600px)');
  window.matchMedia('(prefers-color-scheme: dark)');
  assert.deepEqual(native, ['(max-width: 600px)']);
});

test('a flip fires change on every listener style', () => {
  const { window } = page(false);
  const list = window.matchMedia('(prefers-color-scheme: dark)');
  const seen = [];
  list.addEventListener('change', (e) => seen.push(['event', e.matches]));
  list.addListener((e) => seen.push(['legacy', e.matches]));
  list.onchange = (e) => seen.push(['onchange', e.matches]);
  window.__ksSetDark(true);
  assert.equal(list.matches, true);
  assert.deepEqual(seen, [
    ['event', true], ['legacy', true], ['onchange', true],
  ]);
});

test('setting the same state again stays quiet', () => {
  const { window } = page(true);
  const list = window.matchMedia('(prefers-color-scheme: dark)');
  let fired = 0;
  list.addEventListener('change', () => fired++);
  window.__ksSetDark(true);
  assert.equal(fired, 0);
});

test('a second run keeps the first install', () => {
  const { window } = page(true);
  const setDark = window.__ksSetDark;
  const matchMedia = window.matchMedia;
  runInNewContext(template.replace('$dark', 'false'), {
    window,
    EventTarget,
    Event,
  });
  assert.equal(window.__ksSetDark, setDark);
  assert.equal(window.matchMedia, matchMedia);
});
