import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/gestures/gestures_manager.dart';
import 'package:kiosk_satellite/managers/kiosk/kiosk_link.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A ks://theater link from a dashboard reaching theater mode: the toggle
/// asks the theater manager where it is rather than keeping a copy, and every
/// link says it came from a link.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GesturesManager gestures;
  late List<(String, Map<String, Object?>)> calls;
  late bool active;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    calls = [];
    active = false;
    commands
      ..register(
        Command(
          name: 'getTheaterMode',
          description: 'stub',
          handler: (_) async => CommandResult.ok({'active': active}),
        ),
      )
      ..register(
        Command(
          name: 'setTheaterMode',
          description: 'stub',
          handler: (p) async {
            calls.add(('setTheaterMode', Map.of(p)));
            active = p['active'] == true;
            return const CommandResult.ok(true);
          },
        ),
      )
      ..register(
        Command(
          name: 'theaterPeek',
          description: 'stub',
          handler: (p) async {
            calls.add(('theaterPeek', Map.of(p)));
            return const CommandResult.ok(true);
          },
        ),
      );
    final settings = SettingsManager(bus, commands, log);
    await settings.init();
    gestures = GesturesManager(bus, commands, log, settings);
  });

  Future<void> follow(String link) =>
      gestures.runGestureAction(kioskLinkAction(link)!);

  test('the toggle turns it on, then off', () async {
    await follow('ks://theater');
    expect(active, isTrue);
    await follow('ks://theater');
    expect(active, isFalse);
    expect(calls.map((c) => c.$2['source']), ['link', 'link']);
  });

  test('on, off and peek do what they say, as a link', () async {
    await follow('ks://theater/on');
    await follow('ks://theater/peek');
    await follow('ks://theater/off');
    expect(calls.map((c) => c.$1), [
      'setTheaterMode',
      'theaterPeek',
      'setTheaterMode',
    ]);
    expect(calls.first.$2, {'active': true, 'source': 'link'});
    expect(calls.last.$2, {'active': false, 'source': 'link'});
  });
}
