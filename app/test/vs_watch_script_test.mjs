import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(
  new URL('../lib/managers/browser/vs_watch_script.dart', import.meta.url),
  'utf8',
).split("'''")[1];

const ENTITY = 'assist_satellite.test_panel';

// `store` stands in for sessionStorage, which outlives a reload. Pass the same
// Map to a second page() to model the page reloading in the same tab.
function page({
  engine = true,
  config = JSON.stringify({ satellite_entity: ENTITY }),
  connected = true,
  state = 'idle',
  store = new Map(),
} = {}) {
  let now = 1_700_000_000_000;
  let tick = null;
  const reports = [];
  const hass = { connected, states: {} };
  if (state !== null) hass.states[ENTITY] = { state };

  const context = vm.createContext({
    window: {
      localStorage: { getItem: k => (k === 'vs-panel-config' ? config : null) },
      sessionStorage: {
        getItem: k => (store.has(k) ? store.get(k) : null),
        setItem: (k, v) => store.set(k, v),
        removeItem: k => store.delete(k),
      },
      customElements: { get: n => (engine && n === 'voice-satellite-card' ? {} : undefined) },
      flutter_inappwebview: {
        callHandler: (name, ...args) => { reports.push({ name, args }); },
      },
    },
    document: { querySelector: s => (s === 'home-assistant' ? { hass } : null) },
    setInterval: fn => { tick = fn; },
    Date: { now: () => now },
    JSON, Math, parseInt,
  });
  vm.runInContext(source, context);

  return {
    reports, store,
    state(v) { hass.states[ENTITY] = { state: v }; },
    connected(v) { hass.connected = v; },
    advance(ms) { now += ms; },
    check() { tick(); },
    settle() { this.check(); this.advance(61_000); this.check(); },
  };
}

test('reloads a session that was alive and then stayed unavailable', () => {
  const p = page();
  p.check();
  p.state('unavailable');
  p.settle();
  assert.equal(p.reports.length, 1);
  assert.equal(p.reports[0].name, 'ksVoiceSatelliteDown');
  assert.equal(p.reports[0].args[0], ENTITY);
  assert.ok(p.reports[0].args[1] >= 60, 'reports how long it was down');
});

test('reloads a session that never started', () => {
  // The .145 case on 16 Sept: the engine threw on a null hass.states, the
  // session never registered, and the page had never seen the satellite
  // alive. A reload is exactly what repairs it.
  const p = page({ state: 'unavailable' });
  p.settle();
  assert.equal(p.reports.length, 1);
});

test('waits out a brief gap rather than reloading on the first sample', () => {
  const p = page();
  p.check();
  p.state('unavailable');
  p.check();
  p.advance(30_000);
  p.check();
  assert.deepEqual(p.reports, []);
  p.state('idle');
  p.advance(30_000);
  p.check();
  assert.deepEqual(p.reports, []);
});

test('leaves a panel whose bundle was never delivered alone', () => {
  // No engine: unavailable by design, a reload is futile, and without this
  // guard the panel would reload every cooldown forever.
  const p = page({ engine: false, state: 'unavailable' });
  p.settle();
  p.settle();
  assert.deepEqual(p.reports, []);
});

test('gives up after three reloads rather than cycling forever', () => {
  const store = new Map();
  let total = 0;
  for (let reload = 0; reload < 6; reload++) {
    const p = page({ state: 'unavailable', store });
    p.settle();
    total += p.reports.length;
  }
  assert.equal(total, 3, 'stops asking once the cap is reached');
});

test('a session that comes back clears the reload budget', () => {
  const store = new Map();
  const a = page({ state: 'unavailable', store });
  a.settle();
  assert.equal(a.reports.length, 1);
  assert.equal(store.get('ks-vs-reloads'), '1');

  // Next load works, which must return the full budget for a later outage.
  const b = page({ state: 'idle', store });
  b.check();
  assert.equal(store.has('ks-vs-reloads'), false);

  let total = 0;
  for (let reload = 0; reload < 5; reload++) {
    const p = page({ state: 'unavailable', store });
    p.settle();
    total += p.reports.length;
  }
  assert.equal(total, 3, 'a fresh budget, not a burnt one');
});

test('defers to the socket watchdog while Home Assistant is disconnected', () => {
  const p = page();
  p.check();
  p.connected(false);
  p.state('unavailable');
  p.settle();
  assert.deepEqual(p.reports, []);
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

test('survives sessionStorage being unavailable', () => {
  // Private-mode style: every accessor throws. The watcher must still work,
  // just without a persistent cap.
  const p = page({ state: 'unavailable' });
  assert.doesNotThrow(() => p.settle());
});
