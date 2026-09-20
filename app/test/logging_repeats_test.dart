import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/logging.dart';

/// The ring is a diagnostic record, and polling was erasing it: identical
/// lines close together collapse into one carrying a count, so what is worth
/// reading later survives the night.
void main() {
  late Logger log;

  setUp(() => log = Logger());
  tearDown(() => log.dispose());

  List<String> messages() => [for (final e in log.recent) e.message];

  test(
    'a repeated poll is one line, and the tally arrives when it stops',
    () async {
      for (var i = 0; i < 50; i++) {
        log.info('command', 'getDashboardState [plugin:network-diagnostics]');
      }
      // One line so far: the run is still open, so its count is not known yet.
      expect(messages(), ['getDashboardState [plugin:network-diagnostics]']);

      // Something else, long enough later that the run has gone quiet.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      log.info('wake_word', 'detected "hey_silver_tree"');

      final seen = log.recent;
      expect(seen.length, 2);
      expect(seen[1].message, 'detected "hey_silver_tree"');
      // The tally is emitted only once the run expires, which needs the window
      // to pass; until then the single opening line stands for it.
      expect(seen[0].repeats, 1);
    },
  );

  test('the thing worth finding is not evicted by the noise', () {
    log.info('wake_word', 'detected "hey_fuckface"');
    // Far more polls than the ring can hold, from a handful of distinct lines.
    for (var i = 0; i < 20000; i++) {
      log.info('command', 'getLightLevel [esphome]');
      log.info('command', 'getDeviceDetails [esphome]');
      log.info('command', 'vsEngineState [esphome]');
    }
    expect(messages(), contains('detected "hey_fuckface"'));
    expect(log.recent.length, lessThan(10));
  });

  test('distinct lines are never merged', () {
    log.info('command', 'getLightLevel [esphome]');
    log.info('command', 'getDeviceDetails [esphome]');
    log.warn('command', 'getLightLevel [esphome]');
    expect(messages().length, 3);
  });

  test('a count rides in the wire format, and a single line carries none', () {
    log.info('tag', 'once');
    final json = log.recent.single.toJson();
    expect(json['message'], 'once');
    expect(json.containsKey('repeats'), isFalse);

    final tallied = LogEntry(
      DateTime.now(),
      LogLevel.info,
      'command',
      'getLightLevel [esphome]',
      repeats: 42,
    ).toJson();
    expect(tallied['message'], 'getLightLevel [esphome] (x42)');
    expect(tallied['repeats'], 42);
  });

  test('a live tail sees each distinct line once, not every repeat', () async {
    final seen = <String>[];
    final sub = log.stream.listen((e) => seen.add(e.message));
    log.info('a', 'first');
    log.info('a', 'first');
    log.info('a', 'second');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    // The repeat is suppressed rather than streamed twice; the distinct line
    // is not.
    expect(seen, ['first', 'second']);
  });

  test('a repeated error is never collapsed', () {
    // A renderer retrying every thirty seconds is a shape worth seeing.
    for (var i = 0; i < 5; i++) {
      log.error('dlna', 'renderer startup failed');
      log.warn('dlna', 'retrying');
    }
    expect(
      log.recent.where((e) => e.level == LogLevel.error).length,
      5,
      reason: 'each failure is its own line',
    );
    expect(log.recent.where((e) => e.level == LogLevel.warn).length, 5);
  });
}
