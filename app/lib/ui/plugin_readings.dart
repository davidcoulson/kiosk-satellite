import '../l10n/messages.dart';
import 'package:flutter/material.dart';

import 'kit.dart';
import 'theme.dart';

/// A plugin's confirmed entity states, displayed without editing controls.
class PluginReadings extends StatelessWidget {
  const PluginReadings({super.key, required this.readings, this.title});

  final List<Map<String, Object?>> readings;
  final String? title;

  @override
  Widget build(BuildContext context) {
    if (readings.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(title ?? pluginText(context, 'Readings')),
        SettingsCard(
          children: [
            for (final reading in readings)
              _ReadingRow(
                key: ValueKey('${reading['type']}:${reading['key']}'),
                reading: reading,
              ),
          ],
        ),
      ],
    );
  }
}

/// A reading rendered for a person: the number, and the unit that number is
/// actually in, which is not always the unit the plugin published.
typedef PluginReading = ({String value, String unit});

/// Formats one reading, rescaling by device class where a raw base-unit
/// figure is unreadable.
///
/// A plugin publishes base units and says what kind of quantity it is --
/// `data_size` in bytes, `duration` in seconds -- because that is what keeps
/// a Home Assistant sensor coherent: a statistic whose unit changes from KB
/// to MB as the number grows is a broken statistic. Scaling for display
/// therefore belongs here rather than in the plugin, and doing it here fixes
/// every plugin at once. This is the same split Home Assistant's own
/// frontend makes.
///
/// Anything without a device class this understands is left exactly as it
/// was, at the precision the plugin asked for.
PluginReading formatPluginReading(Map<String, Object?> reading) {
  final state = reading['state'];
  final unit = '${reading['unit'] ?? ''}';
  if (state == null) return (value: 'No data', unit: '');
  if (state is bool) return (value: state ? 'On' : 'Off', unit: '');
  if (state is num) {
    if (!state.isFinite) return (value: 'No data', unit: '');
    final deviceClass = '${reading['deviceClass'] ?? ''}';
    if (deviceClass == 'duration') {
      return (value: _duration(state, unit), unit: '');
    }
    if (deviceClass == 'data_size' || deviceClass == 'data_rate') {
      final scaled = _dataSize(state, unit);
      if (scaled != null) return scaled;
    }
    final precision = ((reading['accuracyDecimals'] as num?)?.toInt() ?? 0)
        .clamp(0, 6);
    if (state.abs() >= 1e9) {
      return (value: state.toStringAsExponential(precision), unit: unit);
    }
    final text = state.toStringAsFixed(precision);
    return (
      value: num.parse(text) == 0 ? 0.toStringAsFixed(precision) : text,
      unit: unit,
    );
  }
  return (value: state == '' ? 'Empty' : '$state', unit: '');
}

/// Bytes at a readable magnitude, to one decimal.
///
/// 1024 rather than 1000, labelled KB/MB/GB: the powers-of-two step is what
/// every file manager and download shows, and writing KiB to be correct
/// about it would leave the row less readable than the number it replaced.
///
/// A rate keeps its denominator -- `B/min` scales to `KB/min`, not to `KB`,
/// which would silently turn a throughput into a total. Whole bytes stay
/// whole: "834 B" reads better than "834.0 B".
PluginReading? _dataSize(num state, String unit) {
  final slash = unit.indexOf('/');
  final base = slash == -1 ? unit : unit.substring(0, slash);
  final per = slash == -1 ? '' : unit.substring(slash);
  if (base != 'B') return null;

  const steps = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = state.toDouble();
  final negative = value < 0;
  value = value.abs();
  var step = 0;
  while (value >= 1024 && step < steps.length - 1) {
    value /= 1024;
    step++;
  }
  final text = step == 0
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return (value: negative ? '-$text' : text, unit: '${steps[step]}$per');
}

/// A span of time as `3d 5h 2m 9s`, largest unit first.
///
/// Leading and trailing zero components are dropped, so an hour reads `1h`
/// rather than `0d 1h 0m 0s`, and a gap in the middle is kept because
/// `1h 0m 9s` and `1h 9s` say different things about the magnitude at a
/// glance. Zero is `0s`, not nothing.
String _duration(num state, String unit) {
  var seconds = state.round();
  if (unit == 'ms') seconds = (state / 1000).round();
  if (unit == 'min') seconds = (state * 60).round();
  if (unit == 'h') seconds = (state * 3600).round();
  final sign = seconds < 0 ? '-' : '';
  seconds = seconds.abs();
  if (seconds == 0) return '0s';

  final parts = <String>[];
  for (final (size, suffix) in [
    (86400, 'd'),
    (3600, 'h'),
    (60, 'm'),
    (1, 's'),
  ]) {
    final count = seconds ~/ size;
    seconds -= count * size;
    if (count == 0 && parts.isEmpty) continue;
    parts.add('$count$suffix');
  }
  while (parts.length > 1 && parts.last.startsWith('0')) {
    parts.removeLast();
  }
  return '$sign${parts.join(' ')}';
}

class _ReadingRow extends StatelessWidget {
  const _ReadingRow({super.key, required this.reading});

  final Map<String, Object?> reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final readingStyle = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: FontWeight.w400,
    );
    final formatted = formatPluginReading(reading);
    final rawValue = formatted.value;
    final state = reading['state'];
    final value =
        state == null ||
            state is bool ||
            state == '' ||
            (state is num && !state.isFinite)
        ? pluginText(context, rawValue)
        : rawValue;
    // The unit comes from the formatter, not the reading: a rescaled figure
    // carries the unit it was rescaled into, and the two must not drift.
    final unit = reading['type'] == 'sensor' && reading['state'] != null
        ? formatted.unit
        : '';
    final multiline = value.contains('\n');
    final label = Text(
      '${reading['name']}',
      style: readingStyle?.copyWith(color: muted),
    );
    final content = Text.rich(
      TextSpan(
        text: value,
        children: [
          if (unit.isNotEmpty)
            TextSpan(
              text: ' $unit',
              style: readingStyle?.copyWith(color: muted),
            ),
        ],
      ),
      // Right-aligned even when it wraps to several lines, so a list reads
      // down the same edge as every single-line value beside it. A ragged
      // left edge is the price; a value column that changes side halfway
      // down the card was the worse one.
      textAlign: TextAlign.end,
      style: readingStyle?.copyWith(
        color: reading['state'] == null || reading['state'] == ''
            ? muted
            : theme.colorScheme.onSurface,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Ks.inset, vertical: 16),
        child: multiline
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [label, const SizedBox(height: 8), content],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 9, child: label),
                  const SizedBox(width: 16),
                  Expanded(flex: 11, child: content),
                ],
              ),
      ),
    );
  }
}
