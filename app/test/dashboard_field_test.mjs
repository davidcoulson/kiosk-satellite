import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// The settings rows for a dashboard view (screensaver.dashboard_view and
// sendspin.fullscreen_return_view) listen for dp-painted after the field's
// first paint, then call field.repaint() so the missing line catches up.
// Without repaint the whole Settings page failed to start (issue #920).
const source = readFileSync(new URL('../remote-ui/static/dashboard_picker.js', import.meta.url), 'utf8');
const start = source.indexOf('export function dashboardField(');
const field = source.slice(start, source.indexOf('\n}\n', start) + 2).replace('export ', '');

class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.classList = { add() {}, toggle() {} }; this.listeners = {}; }
  append(...nodes) { this.children.push(...nodes); }
  appendChild(node) { this.children.push(node); }
  replaceChildren() { this.children = []; }
  addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }
  dispatchEvent(event) { (this.listeners[event.type] || []).forEach((fn) => fn(event)); }
}

function run(catalog) {
  const context = vm.createContext({
    catalog,
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init?.detail; } },
    DASHBOARD_ICON: '',
    el: (tag) => new Element(tag),
    svgPath: () => new Element('svg'),
    glyph: () => new Element('span'),
    mono: (text) => Object.assign(new Element('span'), { text }),
    viewTitle: () => 'View',
    viewIcon: () => '',
    haText: (text) => text,
    matchDashboard: () => null,
    follow: () => {},
    loadDashboards: () => {},
    pickDashboard: async () => null,
  });
  vm.runInContext(`${field}\nglobalThis.dashboardField = dashboardField;`, context);
  return context.dashboardField;
}

test('dashboardField hands back repaint alongside el and setValue', () => {
  const f = run([])({ value: 'home/gone', title: 'View', onPick: () => {} });
  assert.equal(typeof f.repaint, 'function');
  assert.equal(typeof f.setValue, 'function');
});

test('repaint tells a late listener the stored view is gone', () => {
  const f = run([])({ value: 'home/gone', title: 'View', onPick: () => {} });
  const heard = [];
  f.el.addEventListener('dp-painted', (e) => heard.push(e.detail.missing));
  f.repaint();
  assert.deepEqual(heard, [true]);
});

test('repaint reports nothing missing before the dashboards load', () => {
  const f = run(null)({ value: 'home/gone', title: 'View', onPick: () => {} });
  const heard = [];
  f.el.addEventListener('dp-painted', (e) => heard.push(e.detail.missing));
  f.repaint();
  assert.deepEqual(heard, [false]);
});
