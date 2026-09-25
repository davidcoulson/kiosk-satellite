import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

/* The admin's agent trim. The point of the module is that pressing a
   hidden control would fail on the device - those commands are not
   registered in agent mode - so the list of what goes is the contract. */
const source = readFileSync(new URL('../remote-ui/static/agent.js', import.meta.url), 'utf8')
  .replace(/^import .*;$/m, '').replace(/export /g, '');
const html = readFileSync(new URL('../remote-ui/index.html', import.meta.url), 'utf8');

function shell({ agent }) {
  const hidden = new Set();
  const classes = new Set();
  const made = [];
  const el = (id) => ({
    id,
    classList: { add: (c) => hidden.add(`${id}:${c}`), contains: () => false },
    querySelector: () => null,
    appendChild: (child) => made.push(child),
  });
  const groups = [];
  const context = vm.createContext({
    state: { settings: [{ key: 'device.agent_mode', value: agent }] },
    document: {
      body: { classList: { add: (c) => classes.add(c) } },
      querySelector: (sel) => {
        if (sel === '.mbrand') {
          return { querySelector: () => null, appendChild: (c) => made.push(c) };
        }
        const tab = /data-tab="([^"]+)"/.exec(sel);
        if (tab) return el(`tab:${tab[1]}`);
        const cmd = /data-cmd="([^"]+)"/.exec(sel);
        if (cmd) return el(`cmd:${cmd[1]}`);
        return null;
      },
      getElementById: (id) => el(id),
      querySelectorAll: () => groups,
      createElement: () => ({ className: '', textContent: '', title: '' }),
    },
  });
  vm.runInContext(source, context);
  context.applyAgentTrim();
  return { hidden, classes, made };
}

test('a kiosk admin is left exactly as it was', () => {
  const { hidden, classes, made } = shell({ agent: false });
  assert.equal(hidden.size, 0);
  assert.equal(classes.size, 0);
  assert.equal(made.length, 0);
});

test('an agent loses the pages whose managers never start', () => {
  const { hidden } = shell({ agent: true });
  for (const tab of ['homeassistant', 'voicesatellite', 'screensaver', 'browser',
    'sendspin', 'dlna', 'intercom', 'camera', 'cameras', 'kiosk', 'lockdown',
    'home']) {
    assert.ok(hidden.has(`tab:${tab}:hidden`), `${tab} should be hidden`);
  }
});

test('it keeps the pages an agent exists for', () => {
  const { hidden } = shell({ agent: true });
  // Gestures stays for remote keys, a projector's one input.
  for (const tab of ['esphome', 'screenaudio', 'launcher', 'device', 'fleet',
    'files', 'plugins', 'logs', 'about', 'gestures']) {
    assert.ok(!hidden.has(`tab:${tab}:hidden`), `${tab} should stay`);
  }
});

test('quick controls that would fail on the device are removed', () => {
  const { hidden } = shell({ agent: true });
  for (const id of ['tileScreensaver', 'tileCameraView', 'tileDnd', 'tileSnapshot', 'tileExitApp']) {
    assert.ok(hidden.has(`${id}:hidden`), `${id} should be hidden`);
  }
  for (const cmd of ['reload', 'clearWebCache', 'postponeScreensaver']) {
    assert.ok(hidden.has(`cmd:${cmd}:hidden`), `${cmd} should be hidden`);
  }
});

test('an agent says so in the header', () => {
  const { made, classes } = shell({ agent: true });
  assert.equal(made.length, 1);
  assert.equal(made[0].textContent, 'Agent');
  assert.ok(classes.has('agent'));
});

test('every tab and tile the trim names exists in the shell', () => {
  // A rename upstream would otherwise turn this into a list of no-ops.
  const names = [...source.matchAll(/'([a-z]+)'/g)].map((m) => m[1]);
  for (const tab of ['homeassistant', 'voicesatellite', 'screensaver', 'browser',
    'sendspin', 'dlna', 'intercom', 'camera', 'cameras', 'kiosk', 'lockdown',
    'home']) {
    assert.ok(names.includes(tab), `${tab} is named by the trim`);
    assert.ok(html.includes(`data-tab="${tab}"`), `${tab} exists in index.html`);
  }
  for (const id of ['tileScreensaver', 'tileCameraView', 'tileDnd', 'tileSnapshot']) {
    assert.ok(html.includes(`id="${id}"`), `${id} exists in index.html`);
  }
  for (const cmd of ['reload', 'clearWebCache', 'postponeScreensaver']) {
    assert.ok(html.includes(`data-cmd="${cmd}"`), `${cmd} exists in index.html`);
  }
});
