/* The adaptive brightness curve (issues #343 and #742), the device's
   AdaptiveCurve (lib/managers/screen/adaptive_brightness.dart) line for
   line: four points, a monotone cubic through them on the log of the light
   level, flat before the first and after the last, running uphill or, on an
   inverted curve (issue #923), downhill. Pure, so the tests can load it
   without a page. */

const LUX_FLOOR = 0.01;

export const CURVE_KEYS = {
  min: 'screen.adaptive_min_brightness',
  max: 'screen.adaptive_max_brightness',
  dark: 'screen.adaptive_dark_lux',
  bright: 'screen.adaptive_bright_lux',
  p2Position: 'screen.adaptive_point2_position',
  p2Level: 'screen.adaptive_point2_level',
  p3Position: 'screen.adaptive_point3_position',
  p3Level: 'screen.adaptive_point3_level',
  inverted: 'screen.adaptive_inverted',
};

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

/* Crossed light levels and brightness that turned back are flattened, so
   the curve stays a monotone function whatever the settings say mid-edit.
   The ends say which way it runs. */
export function sanePoints(raw) {
  const falling = raw.length > 0
    && clamp(raw[raw.length - 1].level, 0, 1) < clamp(raw[0].level, 0, 1);
  const out = [];
  for (const p of raw) {
    let lux = Math.max(p.lux, LUX_FLOOR);
    let level = clamp(p.level, 0, 1);
    if (out.length) {
      const prev = out[out.length - 1].level;
      lux = Math.max(lux, out[out.length - 1].lux);
      level = falling ? Math.min(level, prev) : Math.max(level, prev);
    }
    out.push({ lux, level });
  }
  return out;
}

/* The four points from the settings: the ends as they are, the middle two
   from their shares of the span between the ends. Inverted (issue #923),
   Dark room sits at Maximum and Bright room at Minimum. */
export function curvePoints(v) {
  const dark = Math.max(v.dark, LUX_FLOOR);
  const bright = Math.max(v.bright, LUX_FLOOR);
  const darkLevel = v.inverted ? v.max : v.min;
  const brightLevel = v.inverted ? v.min : v.max;
  const lux = (position) => Math.exp(Math.log(dark)
    + clamp(position, 0, 1) * (Math.log(bright) - Math.log(dark)));
  const level = (share) => darkLevel + clamp(share, 0, 1) * (brightLevel - darkLevel);
  return sanePoints([
    { lux: dark, level: darkLevel },
    { lux: lux(v.p2Position), level: level(v.p2Level) },
    { lux: lux(v.p3Position), level: level(v.p3Level) },
    { lux: bright, level: brightLevel },
  ]);
}

export function positionFor(lux, darkLux, brightLux) {
  const dark = Math.log(Math.max(darkLux, LUX_FLOOR));
  const bright = Math.log(Math.max(brightLux, LUX_FLOOR));
  if (bright <= dark) return 0;
  return clamp((Math.log(Math.max(lux, LUX_FLOOR)) - dark) / (bright - dark), 0, 1);
}

/* A brightness as a share of the way from the dark end's level to the
   bright end's. */
export function shareFor(level, darkLevel, brightLevel) {
  if (brightLevel === darkLevel) return 0;
  return clamp((level - darkLevel) / (brightLevel - darkLevel), 0, 1);
}

/* Fritsch-Butland tangents: the weighted harmonic mean of the neighboring
   slopes, zero at a flat step or a turn, one-sided at the ends. */
function tangents(xs, ys) {
  const n = xs.length;
  const h = [];
  const d = [];
  for (let i = 0; i < n - 1; i++) {
    h.push(xs[i + 1] - xs[i]);
    d.push(h[i] <= 0 ? 0 : (ys[i + 1] - ys[i]) / h[i]);
  }
  const m = new Array(n).fill(0);
  m[0] = d[0];
  m[n - 1] = d[n - 2];
  for (let i = 1; i < n - 1; i++) {
    if (d[i - 1] * d[i] <= 0) continue;
    const w1 = 2 * h[i] + h[i - 1];
    const w2 = h[i] + 2 * h[i - 1];
    m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i]);
  }
  return m;
}

export function levelAt(points, lux) {
  const first = points[0];
  const last = points[points.length - 1];
  if (lux >= last.lux) return last.level;
  if (lux <= first.lux) return first.level;
  const xs = points.map((p) => Math.log(p.lux));
  const ys = points.map((p) => p.level);
  const x = Math.log(lux);
  let k = 0;
  while (k < points.length - 2 && x >= xs[k + 1]) k++;
  const h = xs[k + 1] - xs[k];
  if (h <= 0) return ys[k + 1];
  const m = tangents(xs, ys);
  const t = (x - xs[k]) / h;
  const t2 = t * t;
  const t3 = t2 * t;
  const y = (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * m[k]
    + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * m[k + 1];
  return clamp(y, Math.min(ys[k], ys[k + 1]), Math.max(ys[k], ys[k + 1]));
}

/* The settings a curve writes, rounded the way the device rounds them. A
   Dark room end above the Bright room end is an inverted curve: Minimum
   and Maximum stay the lower and higher of the two. */
export function curveSettings(p) {
  const level = (v) => Math.round(v * 100) / 100;
  const lux = (v) => Math.round(v * 10) / 10;
  const share = (v) => Number(v.toFixed(6));
  const darkLevel = level(p[0].level);
  const brightLevel = level(p[3].level);
  const inverted = darkLevel > brightLevel;
  const dark = lux(p[0].lux);
  const bright = lux(p[3].lux);
  return {
    [CURVE_KEYS.min]: inverted ? brightLevel : darkLevel,
    [CURVE_KEYS.max]: inverted ? darkLevel : brightLevel,
    [CURVE_KEYS.dark]: dark,
    [CURVE_KEYS.bright]: bright,
    [CURVE_KEYS.p2Position]: share(positionFor(p[1].lux, dark, bright)),
    [CURVE_KEYS.p2Level]: share(shareFor(p[1].level, darkLevel, brightLevel)),
    [CURVE_KEYS.p3Position]: share(positionFor(p[2].lux, dark, bright)),
    [CURVE_KEYS.p3Level]: share(shareFor(p[2].level, darkLevel, brightLevel)),
    [CURVE_KEYS.inverted]: inverted,
  };
}

/* The curve with point i moved. An end that moves takes the middle points
   with it: they keep their shares of the way from the Dark room level to
   the Bright room level, so dragging one end past the other turns the
   whole curve over instead of pinning the end on the middle. */
export function withCurvePoint(p, i, moved) {
  const last = p.length - 1;
  const next = p.map((q, k) => (k === i ? moved : q));
  if (i !== 0 && i !== last) return next;
  for (let k = 1; k < last; k++) {
    const s = shareFor(p[k].level, p[0].level, p[last].level);
    next[k] = { lux: p[k].lux, level: next[0].level + s * (next[last].level - next[0].level) };
  }
  return next;
}

/* A light level for a label: one decimal at most, none when whole. */
export function formatCurveLux(lux) {
  const r = Math.round(lux * 10) / 10;
  return Number.isInteger(r) ? String(r) : r.toFixed(1);
}

/* A dragged light level lands on two significant figures. */
export function snapLux(lux) {
  if (lux <= 0) return 0.1;
  const magnitude = 10 ** (Math.floor(Math.log10(lux)) - 1);
  const snapped = Math.round(lux / magnitude) * magnitude;
  return Math.max(0.1, Math.round(snapped * 10) / 10);
}

export const snapLevel = (level) => Math.round(level * 100) / 100;

/* Where point i may go: between its neighbors in light (a drag keeps a
   little room, a typed value only has to differ). A middle point stays
   between their brightness, whichever way the curve runs. The ends go
   anywhere, past each other too, which inverts the curve. */
export function pointBounds(p, i, domain, gap = 1.12) {
  const last = p.length - 1;
  const end = i === 0 || i === last;
  const levelLo = end ? 0 : Math.min(p[i - 1].level, p[i + 1].level);
  const levelHi = end ? 1 : Math.max(p[i - 1].level, p[i + 1].level);
  return {
    luxLo: i === 0 ? (domain ? domain.lo : 0) : p[i - 1].lux * gap,
    luxHi: i === last ? (domain ? domain.hi : 200000) : p[i + 1].lux / gap,
    levelLo,
    levelHi,
  };
}

/* An end never lands on the other end's brightness: a flat curve has no
   direction. One crossing it hops a step further, or stays put at the
   edge of the chart. */
function pastOtherEnd(level, from, other) {
  if (Math.abs(level - other) >= 0.005) return level;
  const hop = snapLevel(other + (level >= from ? 0.01 : -0.01));
  return hop < 0 || hop > 1 ? from : hop;
}

export function clampPoint(p, i, want, domain) {
  const b = pointBounds(p, i, domain);
  const last = p.length - 1;
  let level = b.levelLo <= b.levelHi ? clamp(want.level, b.levelLo, b.levelHi) : p[i].level;
  if (i === 0 || i === last) level = pastOtherEnd(level, p[i].level, p[last - i].level);
  return {
    lux: b.luxLo <= b.luxHi ? clamp(want.lux, b.luxLo, b.luxHi) : p[i].lux,
    level,
  };
}

/* The chart's light range: whole decades around the ends, with room past
   them to drag, but never past 1 lx or 10k lx (issue #793). Without the
   cap every drag to an edge earned another decade, down to 0.01 lx and up
   to 1M lx. An end typed outside that range still gets its decade. The
   live reading has no say: a dark room's sensor flapping between 0 and
   1 lx would redraw the axis on every sample. A reading outside the range
   sits on the chart's edge. */
const DRAG_LO = 1;
const DRAG_HI = 10000;

export function curveDomain(p) {
  const first = p[0].lux;
  const last = p[p.length - 1].lux;
  const lo = Math.max(Math.min(DRAG_LO, first), LUX_FLOOR);
  const hi = Math.max(10, Math.min(last * 2, DRAG_HI), last);
  return {
    lo: 10 ** Math.floor(Math.log10(lo) + 1e-9),
    hi: 10 ** Math.ceil(Math.log10(hi) - 1e-9),
  };
}
