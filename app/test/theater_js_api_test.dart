import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/js_api/js_api_manager.dart';
import 'package:kiosk_satellite/managers/js_api/user_script.dart';

/// Theater mode on the window.kioskSatellite bridge: the three methods, the
/// event, and the rule that only the start page or Home Assistant, in the
/// main frame, may use them (T-20 to T-23).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EventBus bus;
  late JsApiManager api;
  late List<(String, Map<String, Object?>)> calls;

  Future<void> build() async {
    final log = Logger();
    bus = EventBus();
    final commands = CommandRegistry(log);
    api = JsApiManager(bus, commands, log, '1.0.0');
    await api.init();
    calls = [];
    for (final name in ['setTheaterMode', 'getTheaterMode', 'theaterPeek']) {
      commands.register(
        Command(
          name: name,
          description: 'test stub',
          handler: (p) async {
            calls.add((name, Map.of(p)));
            if (name == 'setTheaterMode' && p['active'] is! bool) {
              return const CommandResult.fail('active must be a boolean');
            }
            if (name == 'getTheaterMode') {
              return const CommandResult.ok({'active': true, 'phase': 'dim'});
            }
            if (name == 'theaterPeek') return const CommandResult.ok(false);
            return const CommandResult.ok(true);
          },
        ),
      );
    }
    api.isTrustedOrigin = (o) =>
        o.host == 'ha.local' || o.host == 'panel.local';
  }

  final page = Uri.parse('http://panel.local:8787');
  final ha = Uri.parse('http://ha.local:8123');

  test('T-20 the three methods map to their commands, and the bridge says '
      'the page asked', () async {
    await build();
    expect(
      await api.handleCall([
        'setTheaterMode',
        {'active': true, 'overlayOpacity': 0.6},
      ], origin: page),
      isTrue,
    );
    expect(calls.single.$2['source'], 'page');
    expect(calls.single.$2['overlayOpacity'], 0.6);
    expect(
      await api.handleCall([
        'getTheaterMode',
        <String, Object?>{},
      ], origin: page),
      {'active': true, 'phase': 'dim'},
    );
    expect(
      await api.handleCall(['theaterPeek', <String, Object?>{}], origin: page),
      isFalse,
      reason: 'off resolves false',
    );
  });

  test('T-21 a non-boolean active resolves false', () async {
    await build();
    expect(
      await api.handleCall([
        'setTheaterMode',
        {'active': 'yes'},
      ], origin: ha),
      isFalse,
    );
  });

  test('a page cannot pass itself off as Home Assistant', () async {
    await build();
    await api.handleCall([
      'setTheaterMode',
      {'active': true, 'source': 'ha'},
    ], origin: ha);
    expect(calls.single.$2['source'], 'page');
  });

  test('T-22 refused from a sub-frame and from another site; allowed from '
      'the start page and Home Assistant', () async {
    await build();
    const on = {'active': true};
    expect(
      await api.handleCall(
        ['setTheaterMode', on],
        origin: ha,
        mainFrame: false,
      ),
      isNull,
    );
    expect(
      await api.handleCall([
        'setTheaterMode',
        on,
      ], origin: Uri.parse('https://evil.example')),
      isNull,
    );
    expect(calls, isEmpty);
    await api.handleCall(['setTheaterMode', on], origin: page);
    await api.handleCall(['setTheaterMode', on], origin: ha);
    expect(calls, hasLength(2));
  });

  test(
    'T-23 a theater event reaches the page as kiosksatellite:theatermode',
    () async {
      await build();
      final seen = <(String, Map<String, Object?>)>[];
      api.debugDispatch = (name, detail) => seen.add((name, detail));
      bus.publish(
        const TheaterModeChanged(active: true, phase: 'dim', source: 'ha'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.single.$1, 'theatermode');
      expect(seen.single.$2, {'active': true, 'phase': 'dim', 'source': 'ha'});
    },
  );

  test('T-20 the injected script defines the methods and passes active as '
      'given', () async {
    final which = await Process.run('which', ['node']);
    if (which.exitCode != 0) {
      markTestSkipped('node is not installed');
      return;
    }
    final script = buildKioskSatelliteScript(version: '1', os: 'android');
    final dir = await Directory.systemTemp.createTemp('ks-js');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/run.js');
    await file.writeAsString(
      [
        'const calls = [];',
        'globalThis.window = globalThis;',
        'window.flutter_inappwebview = {',
        '  callHandler: (h, m, p) => { calls.push([m, p]); '
            'return Promise.resolve(true); },',
        '};',
        'globalThis.document = { addEventListener() {}, '
            "readyState: 'complete' };",
        'globalThis.navigator = {};',
        'try {',
        script,
        '} catch (e) { console.error(String(e)); }',
        '(async () => {',
        '  const ks = window.kioskSatellite;',
        "  const names = ['setTheaterMode', 'getTheaterMode', 'theaterPeek'];",
        "  const out = { defined: names.filter((m) => typeof ks[m] === 'function') };",
        "  await ks.setTheaterMode('yes', { overlayOpacity: 2, peekSeconds: 8 });",
        '  await ks.theaterPeek(30);',
        '  await ks.theaterPeek();',
        '  out.calls = calls.filter(([m]) => names.includes(m));',
        '  console.log(JSON.stringify(out));',
        '})();',
      ].join('\n'),
    );
    final run = await Process.run('node', [file.path]);
    expect(run.exitCode, 0, reason: run.stderr.toString());
    final out =
        jsonDecode(run.stdout.toString().trim().split('\n').last) as Map;
    expect(out['defined'], ['setTheaterMode', 'getTheaterMode', 'theaterPeek']);
    final sent = (out['calls'] as List).cast<List<Object?>>();
    expect(sent[0][0], 'setTheaterMode');
    expect((sent[0][1]! as Map)['active'], 'yes', reason: 'not coerced');
    expect((sent[0][1]! as Map)['overlayOpacity'], 2);
    expect(sent[1], [
      'theaterPeek',
      {'seconds': 30},
    ]);
    expect(sent[2], ['theaterPeek', <String, Object?>{}]);
  });
}
