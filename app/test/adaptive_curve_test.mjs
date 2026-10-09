import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// The remote admin's copy of the adaptive brightness curve (issue #742),
// loaded the way the other pure-module tests load theirs: the module has
// no imports, so its exports run as plain declarations.
const source = readFileSync(new URL('../remote-ui/static/adaptive_curve.js', import.meta.url), 'utf8');
const context = vm.createContext({});
vm.runInContext(source.replace(/^export /gm, ''), context);
const plain = (value) => JSON.parse(JSON.stringify(value));
const {
  curvePoints, curveSettings, levelAt, positionFor, shareFor, curveDomain, clampPoint, snapLux,
  withCurvePoint,
} = context;

const steep = [
  { lux: 5, level: 0.05 },
  { lux: 10, level: 0.10 },
  { lux: 15, level: 0.30 },
  { lux: 300, level: 1.0 },
];
const defaults = {
  min: 0.15, max: 0.8, dark: 5, bright: 300,
  p2Position: 1 / 3, p2Level: 1 / 3, p3Position: 2 / 3, p3Level: 2 / 3,
};

test('the same numbers as the device curve', () => {
  // test/adaptive_brightness_test.dart pins the same values on the device.
  const expected = { 6: 0.060943507576, 7: 0.069020084484, 12: 0.176648713345,
    40: 0.580238677605, 120: 0.808277772294 };
  for (const [lux, level] of Object.entries(expected)) {
    assert.ok(Math.abs(levelAt(steep, Number(lux)) - level) < 1e-9, lux);
  }
});

test('the default middle points draw the straight log line', () => {
  const points = curvePoints(defaults);
  for (const lux of [7, 20, 120]) {
    const t = (Math.log(lux) - Math.log(5)) / (Math.log(300) - Math.log(5));
    assert.ok(Math.abs(levelAt(points, lux) - (0.15 + 0.65 * t)) < 1e-9, String(lux));
  }
  assert.equal(levelAt(points, 1), 0.15);
  assert.equal(levelAt(points, 5000), 0.8);
});

test('never dips where the points climb', () => {
  let last = -1;
  for (let lux = 1; lux <= 1000; lux *= 1.01) {
    const level = levelAt(steep, lux);
    assert.ok(level >= last - 1e-12, String(lux));
    last = level;
  }
});

test('the settings a curve writes read back as the same curve', () => {
  const values = plain(curveSettings(steep));
  assert.equal(values['screen.adaptive_min_brightness'], 0.05);
  assert.equal(values['screen.adaptive_max_brightness'], 1);
  assert.equal(values['screen.adaptive_dark_lux'], 5);
  assert.equal(values['screen.adaptive_bright_lux'], 300);
  assert.ok(Math.abs(values['screen.adaptive_point2_position'] - positionFor(10, 5, 300)) < 1e-6);
  assert.ok(Math.abs(values['screen.adaptive_point3_level'] - shareFor(0.3, 0.05, 1)) < 1e-6);
  const back = curvePoints({
    min: values['screen.adaptive_min_brightness'],
    max: values['screen.adaptive_max_brightness'],
    dark: values['screen.adaptive_dark_lux'],
    bright: values['screen.adaptive_bright_lux'],
    p2Position: values['screen.adaptive_point2_position'],
    p2Level: values['screen.adaptive_point2_level'],
    p3Position: values['screen.adaptive_point3_position'],
    p3Level: values['screen.adaptive_point3_level'],
  });
  back.forEach((p, i) => {
    assert.ok(Math.abs(p.lux - steep[i].lux) < 1e-3, `lux ${i}`);
    assert.ok(Math.abs(p.level - steep[i].level) < 1e-6, `level ${i}`);
  });
});

test('the chart range ignores the live reading, so a flapping sensor never '
  + 'moves the axis', () => {
  // The range takes only the points: no reading can reach it.
  assert.equal(curveDomain.length, 1);
  const points = curvePoints({ min: 0.2, max: 1, dark: 5, bright: 30,
    p2Position: 1 / 3, p2Level: 1 / 3, p3Position: 2 / 3, p3Level: 2 / 3 });
  assert.deepEqual(plain(curveDomain(points)), { lo: 1, hi: 100 });
});

test('dragging the ends to the edges never widens the chart past 1 lx and '
  + '10k lx', () => {
  let points = steep.map((p) => ({ ...p }));
  for (let round = 0; round < 6; round++) {
    for (const [i, lux] of [[0, 0.001], [3, 1e9]]) {
      const domain = plain(curveDomain(points));
      const moved = clampPoint(points, i, { lux, level: points[i].level }, domain);
      points = points.map((p, k) => (k === i ? { ...moved } : p));
    }
  }
  assert.deepEqual(plain(curveDomain(points)), { lo: 1, hi: 10000 });
  assert.equal(points[0].lux, 1);
  assert.equal(points[3].lux, 10000);
  // An end typed past the cap still gets its decade on the chart.
  const typed = curvePoints({ ...defaults, dark: 0.5, bright: 30000 });
  assert.deepEqual(plain(curveDomain(typed)), { lo: 0.1, hi: 100000 });
});

test('a dragged point stays between its neighbors and snaps to two figures', () => {
  const domain = plain(curveDomain(steep));
  assert.deepEqual(domain, { lo: 1, hi: 1000 });
  const moved = plain(clampPoint(steep, 1, { lux: 40, level: 0.9 }, domain));
  assert.ok(moved.lux < 15 && moved.lux > 5 * 1.12);
  assert.equal(moved.level, 0.3);
  assert.equal(snapLux(47.3), 47);
  assert.equal(snapLux(4.73), 4.7);
  assert.equal(snapLux(1234), 1200);
});

// Issue #923: an inverted curve, Dark room at Maximum and Bright room at
// Minimum, for an e-ink reader's backlight.
test('an inverted curve is the device curve upside down', () => {
  const up = curvePoints({ ...defaults });
  const down = curvePoints({ ...defaults, inverted: true });
  assert.equal(down[0].level, 0.8);
  assert.equal(down[3].level, 0.15);
  for (const lux of [1, 5, 7, 20, 120, 300, 900]) {
    assert.ok(Math.abs(levelAt(down, lux) - (0.95 - levelAt(up, lux))) < 1e-9, String(lux));
  }
  const falling = steep.map((p) => ({ lux: p.lux, level: 1 - p.level }));
  let last = 2;
  for (let lux = 1; lux <= 1000; lux *= 1.01) {
    const level = levelAt(falling, lux);
    assert.ok(level <= last + 1e-12, String(lux));
    last = level;
  }
});

test('an inverted curve writes Minimum under Maximum and reads back the same', () => {
  const eink = [
    { lux: 5, level: 1 },
    { lux: 5.3, level: 0.8 },
    { lux: 5.6, level: 0.3 },
    { lux: 6, level: 0 },
  ];
  const values = plain(curveSettings(eink));
  assert.equal(values['screen.adaptive_min_brightness'], 0);
  assert.equal(values['screen.adaptive_max_brightness'], 1);
  assert.equal(values['screen.adaptive_inverted'], true);
  assert.ok(Math.abs(values['screen.adaptive_point2_level'] - 0.2) < 1e-6);
  const back = curvePoints({
    min: values['screen.adaptive_min_brightness'],
    max: values['screen.adaptive_max_brightness'],
    dark: values['screen.adaptive_dark_lux'],
    bright: values['screen.adaptive_bright_lux'],
    p2Position: values['screen.adaptive_point2_position'],
    p2Level: values['screen.adaptive_point2_level'],
    p3Position: values['screen.adaptive_point3_position'],
    p3Level: values['screen.adaptive_point3_level'],
    inverted: values['screen.adaptive_inverted'],
  });
  back.forEach((p, i) => {
    assert.ok(Math.abs(p.lux - eink[i].lux) < 1e-3, `lux ${i}`);
    assert.ok(Math.abs(p.level - eink[i].level) < 1e-6, `level ${i}`);
  });
  assert.equal(plain(curveSettings(steep))['screen.adaptive_inverted'], false);
});

test('dragging an end past the other turns the curve over, middle points '
  + 'and all', () => {
  const points = curvePoints(defaults);
  const domain = plain(curveDomain(points));
  // Landing on the other end's level hops a step past it.
  const onTop = plain(clampPoint(points, 0, { lux: 5, level: 0.8 }, domain));
  assert.equal(onTop.level, 0.81);
  const moved = plain(clampPoint(points, 0, { lux: 5, level: 1 }, domain));
  assert.equal(moved.level, 1);
  const turned = plain(withCurvePoint(points, 0, moved));
  assert.ok(Math.abs(turned[1].level - (1 - 0.2 / 3)) < 1e-9);
  assert.ok(Math.abs(turned[2].level - (1 - 0.4 / 3)) < 1e-9);
  assert.equal(turned[3].level, 0.8);
  // A middle point stays between its neighbors on the way down too.
  const mid = plain(clampPoint(turned, 1, { lux: turned[1].lux, level: 0.5 }, domain));
  assert.ok(Math.abs(mid.level - turned[2].level) < 1e-9);
});
