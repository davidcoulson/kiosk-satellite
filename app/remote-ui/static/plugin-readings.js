// Live entity values use their own DOM so settings drafts and chart selection survive.
function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/**
 * Formats one reading as {value, unit}, rescaling by device class where a
 * raw base-unit figure is unreadable.
 *
 * A plugin publishes base units -- `data_size` in bytes, `duration` in
 * seconds -- because that is what keeps a Home Assistant sensor coherent: a
 * statistic whose unit changes from KB to MB as the number grows is a broken
 * statistic. Scaling for display therefore happens here, and the unit that
 * comes back is the one the value is actually in, which is not always the
 * one the plugin published.
 *
 * Kept in step with formatPluginReading in plugin_readings.dart, deliberately:
 * the panel and Remote Admin read the same entities and must not disagree
 * about what they say.
 */
export function formatPluginReading(reading) {
  const state = reading.state;
  const unit = reading.unit || '';
  if (state == null) return { value: 'No data', unit: '' };
  if (typeof state === 'boolean') return { value: state ? 'On' : 'Off', unit: '' };
  if (typeof state === 'number') {
    if (!Number.isFinite(state)) return { value: 'No data', unit: '' };
    const deviceClass = reading.deviceClass || '';
    if (deviceClass === 'duration') return { value: duration(state, unit), unit: '' };
    if (deviceClass === 'data_size' || deviceClass === 'data_rate') {
      const scaled = dataSize(state, unit);
      if (scaled) return scaled;
    }
    const precision = Math.max(0, Math.min(6, Math.trunc(reading.accuracyDecimals || 0)));
    if (Math.abs(state) >= 1e9) return { value: state.toExponential(precision), unit };
    const value = state.toFixed(precision);
    return { value: Number(value) === 0 ? (0).toFixed(precision) : value, unit };
  }
  return { value: state === '' ? 'Empty' : String(state), unit: '' };
}

/**
 * Bytes at a readable magnitude, to one decimal. 1024 rather than 1000 and
 * labelled KB/MB/GB, the way every file manager shows it. A rate keeps its
 * denominator -- `B/min` becomes `KB/min`, never `KB`, which would turn a
 * throughput into a total.
 */
function dataSize(state, unit) {
  const slash = unit.indexOf('/');
  const base = slash === -1 ? unit : unit.slice(0, slash);
  const per = slash === -1 ? '' : unit.slice(slash);
  if (base !== 'B') return null;

  const steps = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let value = Math.abs(state);
  let step = 0;
  while (value >= 1024 && step < steps.length - 1) { value /= 1024; step++; }
  const text = step === 0 ? String(Math.round(value)) : value.toFixed(1);
  return { value: (state < 0 ? '-' : '') + text, unit: steps[step] + per };
}

/**
 * A span of time as `3d 5h 2m 9s`, largest unit first, with leading and
 * trailing zero components dropped. Zero is `0s`, not nothing.
 */
function duration(state, unit) {
  let seconds = Math.round(
    unit === 'ms' ? state / 1000 : unit === 'min' ? state * 60 : unit === 'h' ? state * 3600 : state);
  const sign = seconds < 0 ? '-' : '';
  seconds = Math.abs(seconds);
  if (seconds === 0) return '0s';

  const parts = [];
  for (const [size, suffix] of [[86400, 'd'], [3600, 'h'], [60, 'm'], [1, 's']]) {
    const count = Math.floor(seconds / size);
    seconds -= count * size;
    if (count === 0 && !parts.length) continue;
    parts.push(`${count}${suffix}`);
  }
  while (parts.length > 1 && parts[parts.length - 1].startsWith('0')) parts.pop();
  return sign + parts.join(' ');
}

export function updatePluginReadings(container, readings, title = 'Readings') {
  readings = Array.isArray(readings) ? readings : [];
  container.hidden = !readings.length;
  if (!readings.length) { container.replaceChildren(); return; }
  let list = container.querySelector('dl');
  if (!list) {
    list = element('dl', 'card plugin-readings-list');
    container.append(element('div', 'card-title', title), list);
  }
  const existing = new Map([...list.children].map(row => [row.dataset.key, row]));
  for (const reading of readings) {
    const key = `${reading.type}:${reading.key}`;
    let row = existing.get(key);
    if (!row) {
      row = element('div', 'plugin-reading'); row.dataset.key = key;
      row.append(element('dt'), element('dd'));
    }
    existing.delete(key);
    const formatted = formatPluginReading(reading);
    const value = formatted.value;
    // From the formatter, not the reading: a rescaled figure carries the
    // unit it was rescaled into, and the two must not drift apart.
    const unit = reading.type === 'sensor' && reading.state != null ? formatted.unit : '';
    row.classList.toggle('multiline', value.includes('\n'));
    const label = row.querySelector('dt');
    if (label.textContent !== reading.name) label.textContent = reading.name;
    const content = row.querySelector('dd');
    content.classList.toggle('muted', reading.state == null || reading.state === '');
    const signature = JSON.stringify([value, unit]);
    if (row.dataset.value !== signature) {
      content.replaceChildren(element('span', 'plugin-reading-value', value));
      if (unit) content.append(document.createTextNode(' '), element('span', 'plugin-reading-unit', unit));
      row.dataset.value = signature;
    }
    list.append(row);
  }
  for (const row of existing.values()) row.remove();
}
