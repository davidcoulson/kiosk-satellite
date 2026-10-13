import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/js_api/page_state_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a page can ask the kiosk about itself: the two themes and the
/// kiosk's modes and overlays, as getters and as change events.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EventBus bus;
  late CommandRegistry commands;
  late SettingsManager settings;
  late PageStateManager state;
  late ValueNotifier<bool?> dashboardDark;
  late ValueNotifier<String?> saverView;
  late ValueNotifier<String?> cameraView;
  late List<AppEvent> events;
  var locked = false;
  var lockdown = false;
  var saverActive = false;
  var media = <String, String>{
    'state': 'idle',
    'title': '',
    'artist': '',
    'source': '',
  };

  Future<void> build([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues({
      'ks.ui.theme': 'light',
      ...initial,
    });
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    commands.register(
      Command(
        name: 'isScreenOn',
        description: 'stub',
        handler: (_) async => const CommandResult.ok(true),
      ),
    );
    dashboardDark = ValueNotifier(null);
    saverView = ValueNotifier(null);
    cameraView = ValueNotifier(null);
    locked = false;
    lockdown = false;
    saverActive = false;
    media = {'state': 'idle', 'title': '', 'artist': '', 'source': ''};
    state = PageStateManager(
      bus,
      commands,
      log,
      settings,
      dashboardDark: dashboardDark,
      kioskLocked: () => locked,
      lockdownActive: () => lockdown,
      screensaverActive: () => saverActive,
      screensaverView: saverView,
      cameraView: cameraView,
      mediaSummary: () => media,
    );
    await state.init();
    events = [];
    bus.stream.listen((e) {
      if (e is ThemeStateChanged || e is KioskStateChanged) events.add(e);
    });
  }

  tearDown(() => state.dispose());

  test('the getters answer both themes and the kiosk state', () async {
    await build({'ks.ha.kiosk_mode': true, 'ks.ha.hold_mode': true});
    final theme = await commands.execute('getTheme', const {});
    expect(theme.data, {
      'app': {'mode': 'light', 'dark': false},
      'homeAssistant': {
        'mode': 'auto',
        'dark': null,
        'scheduled': false,
        'followsApp': false,
      },
    });
    final kiosk =
        (await commands.execute('getKioskState', const {})).data as Map;
    expect(kiosk['kioskMode'], isFalse);
    expect(kiosk['lockdownMode'], isFalse);
    expect(kiosk['haKioskMode'], {
      'enabled': true,
      'hideHeader': true,
      'hideSidebar': true,
    });
    expect(kiosk['screensaver'], {'active': false, 'view': null});
    expect(kiosk['screenOn'], isTrue);
    expect(kiosk['holdMode'], isTrue);
    expect(kiosk['cameraView'], isNull);
    expect(kiosk['mediaPlayer'], {
      'state': 'idle',
      'title': '',
      'artist': '',
      'source': '',
      'nowPlayingShown': false,
    });
  });

  test(
    'a theme change is an event, and so is Home Assistant going dark',
    () async {
      await build();
      await settings.set(defs.uiTheme, 'dark');
      await pumpEventQueue();
      final appDark = events.whereType<ThemeStateChanged>().single;
      expect((appDark.state['app'] as Map)['dark'], isTrue);
      expect(appDark.wireName, 'theme');
      // A custom page follows the app while Home Assistant picks its own.
      expect(state.pageDark.value, isTrue);

      dashboardDark.value = false;
      await pumpEventQueue();
      final haLight = events.whereType<ThemeStateChanged>().last;
      expect((haLight.state['homeAssistant'] as Map)['dark'], isFalse);
      // Home Assistant's state wins once the kiosk sets one.
      expect(state.pageDark.value, isFalse);
    },
  );

  test(
    'the kiosk state event carries the whole snapshot, once per change',
    () async {
      await build();
      saverActive = true;
      saverView.value = 'clock';
      await pumpEventQueue();
      var last = events.whereType<KioskStateChanged>().last;
      expect(last.wireName, 'kiosk-state');
      expect(last.state['screensaver'], {'active': true, 'view': 'clock'});

      final before = events.length;
      // Nothing the snapshot shows moved: no event.
      await settings.set(defs.screensaverTimeoutSeconds, 45);
      await pumpEventQueue();
      expect(events.length, before);

      bus.publish(const ScreenStateChanged(on: false));
      lockdown = true;
      await settings.set(defs.lockdownEnabled, true);
      media = {
        'state': 'playing',
        'title': 'Song',
        'artist': 'Band',
        'source': 'Kitchen',
      };
      bus.publish(MediaSummaryChanged(media));
      bus.publish(const FullscreenViewChanged(view: 'nowPlaying', shown: true));
      cameraView.value = 'front';
      await pumpEventQueue();
      last = events.whereType<KioskStateChanged>().last;
      expect(last.state['screenOn'], isFalse);
      expect(last.state['lockdownMode'], isTrue);
      expect(last.state['cameraView'], 'front');
      expect(last.state['mediaPlayer'], {
        'state': 'playing',
        'title': 'Song',
        'artist': 'Band',
        'source': 'Kitchen',
        'nowPlayingShown': true,
      });
    },
  );
}
