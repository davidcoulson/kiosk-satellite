import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/ui/plugin_readings.dart';

void main() {
  test(
    'readings distinguish unknown, empty, zero and false with bounded precision',
    () {
      for (final (state, precision, expected) in [
        (null, 0, 'No data'),
        ('', 0, 'Empty'),
        (false, 0, 'Off'),
        (true, 0, 'On'),
        (0, 2, '0.00'),
        (-0.0001, 2, '0.00'),
        (12.3456, 2, '12.35'),
        (12.3456, 0, '12'),
        (1e12, 2, '1.00e+12'),
        (double.nan, 2, 'No data'),
        ('Line one\nLine two', 0, 'Line one\nLine two'),
      ]) {
        expect(
          formatPluginReading({
            'state': state,
            'accuracyDecimals': precision,
          }).value,
          expected,
        );
      }
    },
  );

  test('a data_size reading is rescaled, and carries the unit it landed in', () {
    // The figures that prompted this: a panel's traffic counters, which are
    // published in bytes so the Home Assistant statistic stays coherent and
    // are unreadable at that scale on a settings row.
    for (final (state, expected, unit) in [
      (0, '0', 'B'),
      (834, '834', 'B'),
      // Whole bytes stay whole; a decimal only appears once scaled.
      (1023, '1023', 'B'),
      (1024, '1.0', 'KB'),
      (411099, '401.5', 'KB'),
      (13483830, '12.9', 'MB'),
      (13894929, '13.3', 'MB'),
      (5.0 * 1024 * 1024 * 1024, '5.0', 'GB'),
      (-2048, '-2.0', 'KB'),
    ]) {
      final formatted = formatPluginReading({
        'state': state,
        'unit': 'B',
        'deviceClass': 'data_size',
      });
      expect(formatted.value, expected);
      expect(formatted.unit, unit);
    }

    // A rate keeps its denominator: scaling B/min into KB would turn a
    // throughput into a total.
    final rate = formatPluginReading({
      'state': 9332,
      'unit': 'B/min',
      'deviceClass': 'data_rate',
    });
    expect(rate.value, '9.1');
    expect(rate.unit, 'KB/min');

    // A device class we understand on a unit we do not is left alone rather
    // than guessed at.
    final odd = formatPluginReading({
      'state': 1500,
      'unit': 'packets',
      'deviceClass': 'data_size',
    });
    expect(odd.value, '1500');
    expect(odd.unit, 'packets');
  });

  test('a duration reads as a span of time, not a count of seconds', () {
    for (final (seconds, expected) in [
      (0, '0s'),
      (9, '9s'),
      (60, '1m'),
      (428, '7m 8s'),
      (3600, '1h'),
      (3720, '1h 2m'),
      (3661, '1h 1m 1s'),
      (90000, '1d 1h'),
      (277329, '3d 5h 2m 9s'),
      // A gap in the middle is kept: "1h 0m 9s" and "1h 9s" read as
      // different magnitudes at a glance.
      (3609, '1h 0m 9s'),
    ]) {
      final formatted = formatPluginReading({
        'state': seconds,
        'unit': 's',
        'deviceClass': 'duration',
      });
      expect(formatted.value, expected, reason: '$seconds s');
      expect(formatted.unit, '', reason: 'the span carries its own units');
    }
  });

  test('a reading with no device class is untouched', () {
    final plain = formatPluginReading({
      'state': 13483830,
      'unit': 'B',
      'accuracyDecimals': 0,
    });
    expect(plain.value, '13483830');
    expect(plain.unit, 'B');
  });

  testWidgets(
    'readings wrap at narrow widths and large text without interactive controls',
    (tester) async {
      final readings = <Map<String, Object?>>[
        {
          'type': 'sensor',
          'key': 'cpu',
          'name': 'Simulated wave',
          'state': 12.5,
          'accuracyDecimals': 2,
          'unit': '%',
        },
        {
          'type': 'sensor',
          'key': 'unknown',
          'name': 'Temperature',
          'state': null,
          'unit': '°C',
        },
        {
          'type': 'text_sensor',
          'key': 'summary',
          'name': 'Sample details',
          'state':
              'Pattern: Triangle\nHistory: up to 120 samples\nInterval: 2 seconds',
        },
        {
          'type': 'text_sensor',
          'key': 'long',
          'name': 'Long reading',
          'state': 'a' * 512,
        },
        {
          'type': 'select',
          'key': 'mode',
          'name': 'Current mode',
          'state': 'Automatic',
        },
        {'type': 'switch', 'key': 'switch', 'name': 'Chart', 'state': false},
      ];
      for (final width in [320.0, 760.0]) {
        tester.view.resetPhysicalSize();
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 1000),
                textScaler: const TextScaler.linear(2),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: PluginReadings(readings: readings),
                ),
              ),
            ),
          ),
        );
        expect(find.text('Readings'), findsOneWidget);
        expect(find.text('12.50 %', findRichText: true), findsOneWidget);
        expect(find.text('No data', findRichText: true), findsOneWidget);
        expect(find.text('°C', findRichText: true), findsNothing);
        expect(find.byType(Switch), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pumpWidget(
        const MaterialApp(home: PluginReadings(readings: [])),
      );
      expect(find.text('Readings'), findsNothing);
    },
  );
}
