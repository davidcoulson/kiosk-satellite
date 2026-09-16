import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(
  new URL('../lib/managers/browser/vs_watch_script.dart', import.meta.url),
  'utf8',
).split("'''")[1];

const ENTITY = 'assist_satellite.test_panel';

function page({
  engine = true,
  config = JSON.stringify({ satellite_entity: ENTITY }),
  connected = true,
  state = 'idle',
} = {}) {
  let now = 1_700_000_000_000;
  let tick = null;
  const reports = [];
  const hass = { connected, states: {} };
  if (state !== null) hass.states[ENTITY] = { state };

  const context = vm.createContext({
    window: {
      localStorage: { getItem: k => (k === 'vs-panel-config' ? config : null) },
      customElements: { get: n => (engine && n === 'voice-satellite-card' ? {} : undefined) },
      flutter_inappwebview: {
        callHandler: (name, ...args) => { reports.push({ name, args }); },
      },
    },
    document: { querySelector: s => (s === 'home-assistant' ? { hass } : null) },
    setInterval: fn => { tick = fn; },
    Date: { now: () => now },
    JSON,
    Math,
  });
  context.window.JSON = JSON;
  vm.runInContext(source, context);

  return {
    reports, hass,
    state(v) { hass.states[ENTITY] = { state: v }; },
    connected(v) { hass.connected = v; },
    advance(ms) { now += ms; },
    check() { tick(); },
    // One poll, then enough elapsed time that the next poll is past DOWN_MS.
    settle() { this.check(); this.advance(61_000); this.check(); },
  };
}

test('reloads a session that was alive and then stayed unavailable', () => {
  const p = page();
  p.check();                       // seen alive
  p.state('unavailable');
  p.settle();
  assert.equal(p.reports.length, 1);
  assert.equal(p.reports[0].name, 'ksVoiceSatelliteDown');
  assert.equal(p.reports[0].args[0], ENTITY);
  assert.ok(p.reports[0].args[1] >= 60, 'reports how long it was down');
});

test('waits out a brief gap rather than reloading on the first sample', () => {
  const p = page();
  p.check();
  p.state('unavailable');
  p.check();                       // starts the clock
  p.advance(30_000);
  p.check();                       // still inside the grace window
  assert.deepEqual(p.reports, []);
  p.state('idle');
  p.advance(30_000);
  p.check();                       // came back on its own
  assert.deepEqual(p.reports, []);
});

test('leaves a panel whose bundle was never delivered alone', () => {
  // No engine: the satellite is unavailable by design and a reload is futile,
  // so this must never fire or the panel reloads forever.
  const p = page({ engine: false, state: 'unavailable' });
  p.settle();
  p.settle();
  assert.deepEqual(p.reports, []);
});

test('leaves a session that never started alone', () => {
  const p = page({ state: 'unavailable' });
  p.settle();
  p.settle();
  assert.deepEqual(p.reports, []);
});

test('defers to the socket watchdog while Home Assistant is disconnected', () => {
  const p = page();
  p.check();                       // seen alive
  p.connected(false);
  p.state('unavailable');
  p.settle();
  assert.deepEqual(p.reports, []);
  // Once the socket is back, a still-dead session is ours again.
  p.connected(true);
  p.settle();
  assert.equal(p.reports.length, 1);
});

test('reports once per outage, and arms again after a recovery', () => {
  const p = page();
  p.check();
  p.state('unavailable');
  p.settle();
  assert.equal(p.reports.length, 1);
  p.settle();
  p.settle();
  assert.equal(p.reports.length, 1, 'does not repeat while still down');

  p.state('idle');
  p.check();
  p.state('unavailable');
  p.settle();
  assert.equal(p.reports.length, 2, 'a fresh outage reports again');
});

test('does nothing without a panel config to name the satellite', () => {
  const p = page({ config: null });
  p.settle();
  assert.deepEqual(p.reports, []);
});

test('survives a corrupt panel config', () => {
  const p = page({ config: '{not json' });
  assert.doesNotThrow(() => p.settle());
  assert.deepEqual(p.reports, []);
});
