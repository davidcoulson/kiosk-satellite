import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Brightness;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver;

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';

/// What a page can ask the kiosk about itself (docs/js-api.md): the app's
/// and Home Assistant's light or dark state, and the kiosk's modes and
/// overlays. A custom page has no Home Assistant frontend to read these
/// from, so the kiosk tells it.
///
/// `getTheme` and `getKioskState` answer the current snapshot, and the
/// `theme` and `kiosk-state` events carry a new one whenever anything in
/// it moved. The snapshots are rebuilt on every change that could touch
/// them and only published when they differ from the last one sent.
class PageStateManager extends Manager {
  PageStateManager(
    super.bus,
    super.commands,
    super.log,
    this._settings, {
    required this.dashboardDark,
    required this.kioskLocked,
    required this.lockdownActive,
    required this.screensaverActive,
    required this.screensaverView,
    required this.cameraView,
    required this.mediaSummary,
  });

  final SettingsManager _settings;

  /// The light or dark state the kiosk sets on Home Assistant's frontend,
  /// null while Home Assistant picks its own.
  final ValueListenable<bool?> dashboardDark;
  final bool Function() kioskLocked;
  final bool Function() lockdownActive;
  final bool Function() screensaverActive;
  final ValueListenable<String?> screensaverView;
  final ValueListenable<String?> cameraView;
  final Map<String, String> Function() mediaSummary;

  /// Whether a custom page should render dark: Home Assistant's state when
  /// the kiosk sets one, the app's otherwise. The dashboard WebView makes
  /// a custom page's `prefers-color-scheme` answer with it.
  final pageDark = ValueNotifier<bool>(false);

  @override
  String get name => 'page_state';

  bool _screenOn = true;
  bool _nowPlayingShown = false;
  String _lastTheme = '';
  String _lastKiosk = '';
  final _subs = <StreamSubscription<Object>>[];
  late final _brightness = _BrightnessWatch(_refresh);

  @override
  Future<void> init() async {
    commands
      ..register(
        Command(
          name: 'getTheme',
          description:
              "The app's and Home Assistant's light or dark state, for a "
              'page that follows them (kioskSatellite.getTheme)',
          handler: (_) async => CommandResult.ok(theme()),
        ),
      )
      ..register(
        Command(
          name: 'getKioskState',
          description:
              "The kiosk's modes and overlays: kiosk mode, Lockdown Mode, "
              'Home Assistant kiosk mode, the screensaver, the screen, hold '
              'mode, rotation, the camera view and the media player '
              '(kioskSatellite.getKioskState)',
          handler: (_) async => CommandResult.ok(kioskState()),
        ),
      );
    final screen = await commands.execute('isScreenOn', const {});
    if (screen.ok && screen.data is bool) _screenOn = screen.data as bool;
    _subs
      ..add(bus.on<SettingChanged>().listen((_) => _refresh()))
      ..add(
        bus.on<ScreenStateChanged>().listen((e) {
          _screenOn = e.on;
          _refresh();
        }),
      )
      ..add(bus.on<ScreensaverStateChanged>().listen((_) => _refresh()))
      ..add(bus.on<MediaSummaryChanged>().listen((_) => _refresh()))
      ..add(
        bus.on<FullscreenViewChanged>().listen((e) {
          if (e.view != 'nowPlaying') return;
          _nowPlayingShown = e.shown;
          _refresh();
        }),
      );
    dashboardDark.addListener(_refresh);
    screensaverView.addListener(_refresh);
    cameraView.addListener(_refresh);
    WidgetsBinding.instance.addObserver(_brightness);
    _lastTheme = jsonEncode(theme());
    _lastKiosk = jsonEncode(kioskState());
    pageDark.value = _pageDark();
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    dashboardDark.removeListener(_refresh);
    screensaverView.removeListener(_refresh);
    cameraView.removeListener(_refresh);
    WidgetsBinding.instance.removeObserver(_brightness);
  }

  bool _appDark() => switch (_settings.get(defs.uiTheme)) {
    'dark' => true,
    'light' => false,
    _ =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
  };

  bool _pageDark() => dashboardDark.value ?? _appDark();

  /// What `kioskSatellite.getTheme()` answers.
  Map<String, Object?> theme() => {
    'app': {'mode': _settings.get(defs.uiTheme), 'dark': _appDark()},
    'homeAssistant': {
      'mode': _settings.get(defs.haTheme),
      'dark': dashboardDark.value,
      'scheduled': _settings.get(defs.themeAuto),
      'followsApp': _settings.get(defs.themeMatchApp),
    },
  };

  /// What `kioskSatellite.getKioskState()` answers.
  Map<String, Object?> kioskState() {
    final media = mediaSummary();
    return {
      'kioskMode': kioskLocked(),
      'lockdownMode': lockdownActive(),
      'haKioskMode': {
        'enabled': _settings.get(defs.haKioskMode),
        'hideHeader': _settings.get(defs.haKioskHideHeader),
        'hideSidebar': _settings.get(defs.haKioskHideSidebar),
      },
      'screensaver': {
        'active': screensaverActive(),
        'view': screensaverView.value,
      },
      'screenOn': _screenOn,
      'holdMode': _settings.get(defs.haHoldMode),
      'rotation': _settings.get(defs.haRotationEnabled),
      'cameraView': cameraView.value,
      'mediaPlayer': {
        'state': media['state'] ?? 'idle',
        'title': media['title'] ?? '',
        'artist': media['artist'] ?? '',
        'source': media['source'] ?? '',
        'nowPlayingShown': _nowPlayingShown,
      },
    };
  }

  void _refresh() {
    final theme = this.theme();
    final themeJson = jsonEncode(theme);
    if (themeJson != _lastTheme) {
      _lastTheme = themeJson;
      bus.publish(ThemeStateChanged(theme));
    }
    pageDark.value = _pageDark();
    final kiosk = kioskState();
    final kioskJson = jsonEncode(kiosk);
    if (kioskJson != _lastKiosk) {
      _lastKiosk = kioskJson;
      bus.publish(KioskStateChanged(kiosk));
    }
  }
}

/// The device's own dark mode, which the app follows on System.
class _BrightnessWatch with WidgetsBindingObserver {
  _BrightnessWatch(this.onChanged);

  final void Function() onChanged;

  @override
  void didChangePlatformBrightness() => onChanged();
}
