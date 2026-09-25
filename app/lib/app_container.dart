import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core/command_registry.dart';
import 'core/event_bus.dart';
import 'core/logging.dart';
import 'core/manager.dart';
import 'managers/plugins/plugin_manager.dart';
import 'managers/shizuku/shizuku_manager.dart';
import 'managers/assist_pipeline/assist_pipeline_manager.dart';
import 'managers/audio/audio_routing_manager.dart';
import 'managers/browser/browser_manager.dart';
import 'managers/browser/navigation.dart';
import 'managers/camera/camera_manager.dart';
import 'managers/device/device_manager.dart';
import 'managers/device_camera/device_camera_manager.dart';
import 'managers/btproxy/bt_proxy_manager.dart';
import 'managers/dlna/dlna_manager.dart';
import 'managers/files/files_manager.dart';
import 'managers/gestures/gestures_manager.dart';
import 'managers/glance/glance_manager.dart';
import 'managers/home_assistant/home_assistant_manager.dart';
import 'managers/js_api/js_api_manager.dart';
import 'managers/kiosk/kiosk_manager.dart';
import 'managers/launcher/app_launcher_manager.dart';
import 'managers/launcher/home_launcher_manager.dart';
import 'managers/motion/motion_manager.dart';
import 'managers/notifications/notification_manager.dart';
import 'managers/fleet/fleet_manager.dart';
import 'managers/fleet/fleet_sync_manager.dart';
import 'managers/intercom/intercom_manager.dart';
import 'managers/analytics/analytics_manager.dart';
import 'managers/location/location_manager.dart';
import 'managers/person/person_sensor_manager.dart';
import 'managers/proximity/proximity_manager.dart';
import 'managers/proxy/proxy_manager.dart';
import 'managers/remote/remote_manager.dart';
import 'managers/screen/screen_manager.dart';
import 'managers/screensaver/immich_manager.dart';
import 'managers/screensaver/screensaver_manager.dart';
import 'managers/sendspin/sendspin_manager.dart';
import 'managers/service/service_manager.dart';
import 'managers/sound/sound_manager.dart';
import 'managers/settings/provisioning.dart';
import 'managers/settings/definitions.dart' as defs;
import 'managers/settings/settings_manager.dart';
import 'managers/theater/theater_manager.dart';
import 'managers/update/update_manager.dart';
import 'managers/voice_timers/voice_timer_manager.dart';
import 'managers/wake_word/wake_word_manager.dart';

/// Composition root. Construction does no work; [init] brings managers up in
/// dependency-safe order (settings first, remote last so everything it
/// administers already exists).
class AppContainer {
  AppContainer() {
    settings = SettingsManager(bus, commands, log);
    device = DeviceManager(bus, commands, log, settings);
    screen = ScreenManager(bus, commands, log, settings);
    service = ServiceManager(bus, commands, log, settings);
    proxy = ProxyManager(bus, commands, log, settings);
    browser = BrowserManager(bus, commands, log, settings);
    // Constructed before camera, which streams Home Assistant camera
    // entities through its WebRTC signaling (issue #124). Construction
    // order only; init order below is unchanged.
    homeAssistant = HomeAssistantManager(bus, commands, log, settings);
    camera = CameraManager(bus, commands, log, settings, homeAssistant);
    // Composition-root wiring, not a manager-to-manager reference: every
    // page load funnels through BrowserManager.loadUrl, and the proxy is
    // the one that knows whether the URL must move to the loopback origin.
    browser.urlMapper = proxy.mapUrl;
    kiosk = KioskManager(bus, commands, log, settings);
    launcher = AppLauncherManager(bus, commands, log, settings);
    homeLauncher = HomeLauncherManager(bus, commands, log, settings);
    gestures = GesturesManager(bus, commands, log, settings);
    screensaver = ScreensaverManager(bus, commands, log, settings);
    theater = TheaterManager(bus, commands, log, settings)
      ..isTrustedOrigin = _isConfiguredOrigin;
    immich = ImmichManager(bus, commands, log, settings);
    // Before motion: its init runs the legacy motion-camera migration the
    // motion manager's gate reads.
    deviceCamera = DeviceCameraManager(bus, commands, log, settings);
    motion = MotionManager(bus, commands, log, settings);
    proximity = ProximityManager(bus, commands, log, settings);
    location = LocationManager(bus, commands, log, settings);
    analytics = AnalyticsManager(bus, commands, log, settings);
    personSensor = PersonSensorManager(bus, commands, log, settings);
    // Before wakeWord: its init seeds the mic selector the engine reads at
    // start, and its SettingChanged subscription must run before wakeWord's
    // restart re-opens capture.
    audio = AudioRoutingManager(bus, commands, log, settings);
    wakeWord = WakeWordManager(bus, commands, log, settings);
    // After wakeWord: the native pipeline transport consumes the engine's
    // in-process audio stream through it (issue-free: one consumer per
    // turn, negotiated by Voice Satellite).
    pipeline = AssistPipelineManager(bus, commands, log, settings, wakeWord);
    sendspin = SendspinManager(bus, commands, log, settings);
    dlna = DlnaManager(bus, commands, log, settings);
    btProxy = BtProxyManager(bus, commands, log, settings);
    // Composition-root wiring: the opaque full-screen overlays report their
    // visibility so the dashboard WebView stops compositing underneath
    // them. The settings route reports from the UI, where its transition
    // timing lives; these two have clean manager-side edges.
    camera.activeViewId.addListener(
      () => browser.setCovered(
        'camera view',
        covered: camera.activeViewId.value != null,
      ),
    );
    void syncDlnaCover() =>
        browser.setCovered('dlna', covered: dlna.coversScreen);
    dlna.media.addListener(syncDlnaCover);
    dlna.transportState.addListener(syncDlnaCover);
    dlna.pending.addListener(syncDlnaCover);
    files = FilesManager(bus, commands, log);
    sound = SoundManager(bus, commands, log, settings: settings);
    voiceTimers = VoiceTimerManager(bus, commands, log);
    notifications = NotificationManager(bus, commands, log, settings);
    update = UpdateManager(
      bus,
      commands,
      log,
      useShizuku: () => settings.get(shizukuInstallUpdates),
      customSource: () => settings.get(updateSource) == 'custom'
          ? settings.get(updateSourceUrl).trim()
          : null,
    );
    // After homeAssistant: it reads states through it for the fallback.
    glance = GlanceManager(bus, commands, log, settings, homeAssistant);
    shizuku = ShizukuManager(bus, commands, log);
    plugins = PluginManager(bus, commands, log);
    settings.pluginScreensavers = () => plugins.screensaverOptions;
    remote = RemoteManager(bus, commands, log, settings);
    fleet = FleetManager(bus, commands, log, settings);
    fleetSync = FleetSyncManager(bus, commands, log, settings);
    intercom = IntercomManager(bus, commands, log, settings);
  }

  final bus = EventBus();
  final log = Logger();
  // The device's own UI executes through this handle; every manager
  // re-scopes it under its own name.
  late final commands = CommandRegistry(log).as('ui');

  late final SettingsManager settings;
  late final DeviceManager device;
  late final ScreenManager screen;
  late final ServiceManager service;
  late final ProxyManager proxy;
  late final BrowserManager browser;
  late final CameraManager camera;
  late final KioskManager kiosk;
  late final AppLauncherManager launcher;
  late final HomeLauncherManager homeLauncher;
  late final GesturesManager gestures;
  late final ScreensaverManager screensaver;
  late final TheaterManager theater;
  late final ImmichManager immich;
  late final DeviceCameraManager deviceCamera;
  late final MotionManager motion;
  late final ProximityManager proximity;
  late final LocationManager location;
  late final AnalyticsManager analytics;
  late final PersonSensorManager personSensor;
  late final HomeAssistantManager homeAssistant;
  late final AudioRoutingManager audio;
  late final WakeWordManager wakeWord;
  late final AssistPipelineManager pipeline;
  late final SendspinManager sendspin;
  late final DlnaManager dlna;
  late final BtProxyManager btProxy;
  late final FilesManager files;
  late final GlanceManager glance;
  late final SoundManager sound;
  late final VoiceTimerManager voiceTimers;
  late final NotificationManager notifications;
  late final UpdateManager update;
  late final ShizukuManager shizuku;
  late final PluginManager plugins;
  late final RemoteManager remote;
  late final FleetManager fleet;
  late final FleetSyncManager fleetSync;
  late final IntercomManager intercom;

  /// Built after [device.init] so it can carry the app version, and only
  /// for a kiosk: the page bridge has nothing to attach to without a
  /// browser, and every caller of it lives in KioskScreen.
  late final JsApiManager jsApi;
  bool _jsApiBuilt = false;

  /// Whether this install runs as a management agent rather than a kiosk.
  /// Read from the settings, which are loaded before anything below starts.
  bool get agentMode => settings.get(defs.agentMode);

  /// What agent mode leaves out: everything whose job is to face a person
  /// through this device's own screen or microphone. The app launcher is a
  /// deliberate exception - its overlay never opens on an agent, but it owns
  /// installedApps, foregroundApp and the foreground_app sensor, and "which
  /// app is this projector running" is most of what an agent is for. What stays is what a
  /// projector or a media box is actually useful for - the ESPHome device
  /// and its sensors (btProxy owns that surface), the remote admin, updates,
  /// plugins and fleet membership - plus the pieces those rest on: the
  /// foreground service, the screen state, files and Shizuku.
  ///
  /// Skipped rather than disabled. Each of these can already be turned off
  /// by its own setting, but every one of them is still constructed here and
  /// still runs init(), and init() is where the cost is: a WebView, a camera
  /// binding, an audio engine, platform channels and settings listeners, on
  /// a box that will never show a dashboard. The objects themselves are
  /// cheap and are built either way - this list is about what never starts.
  List<Manager> get _agentOmits => [
    browser,
    camera,
    kiosk,
    homeLauncher,
    screensaver,
    theater,
    immich,
    deviceCamera,
    motion,
    proximity,
    personSensor,
    audio,
    gestures,
    wakeWord,
    pipeline,
    sendspin,
    dlna,
    glance,
    sound,
    voiceTimers,
    notifications,
    intercom,
  ];

  List<Manager> get _ordered {
    final all = _everyManager;
    if (!agentMode) return all;
    final omit = Set<Manager>.identity()..addAll(_agentOmits);
    return all.where((m) => !omit.contains(m)).toList();
  }

  List<Manager> get _everyManager => [
    settings,
    device,
    screen,
    service,
    proxy,
    browser,
    camera,
    if (_jsApiBuilt) jsApi,
    kiosk,
    // After kiosk: it listens for the AppLaunched its launchApp emits,
    // and its bringToFront/screenOn calls resolve at execute time.
    launcher,
    // Same placement logic: its role relays arrive as bus events KioskManager
    // forwards, and its acquire path invokes the kiosk_lock channel.
    homeLauncher,
    screensaver,
    // After screen (its holdBrightness) and screensaver, which stands down
    // on the event this publishes. Nothing here runs until something turns
    // theater mode on.
    theater,
    immich,
    deviceCamera,
    motion,
    proximity,
    location,
    // After device (its info feeds every report) and settings; its first
    // report waits minutes anyway.
    analytics,
    personSensor,
    homeAssistant,
    audio,
    // After kiosk (it relays GestureDetected) and after audio: gestures may
    // open the shared microphone for clap detection at init, and the capture
    // selector and tuning must be seeded first. Commands resolve at execute
    // time, so running late costs nothing.
    gestures,
    wakeWord,
    pipeline,
    sendspin,
    dlna,
    btProxy,
    files,
    glance,
    sound,
    voiceTimers,
    notifications,
    update,
    shizuku,
    plugins,
    remote,
    // After remote: it announces the admin server the remote manager runs.
    fleet,
    // After fleet: it reads this kiosk's id and the others from it.
    fleetSync,
    // After fleet too: the roster is the switcher's list. After sound: it
    // chimes through it.
    intercom,
  ];

  /// Agent mode's one borrowed command.
  ///
  /// restartApp belongs to the kiosk manager, which an agent does not run -
  /// and turning agent mode off needs a restart to take effect. Without this
  /// an agent could be switched on from the remote admin and not switched
  /// back off from it, which on a projector with no keyboard means fetching
  /// a laptop and adb. The kiosk manager's own version refuses first on
  /// Android 10+ without the draw-over-apps grant, because a process that
  /// cannot bring itself back must not kill itself; nothing about that
  /// changes here.
  @visibleForTesting
  void registerAgentRestart() {
    const background = MethodChannel('kiosk_satellite/background');
    commands.register(
      Command(
        name: 'restartApp',
        description:
            'Kill and relaunch the whole app. In agent mode this is what '
            'applies a change to Agent mode itself.',
        handler: (_) async {
          final info = await commands.execute('getDeviceInfo', const {});
          final sdk = info.data is Map
              ? ((info.data as Map)['sdkInt'] as num?)?.toInt()
              : null;
          if (sdk != null && sdk >= 29) {
            final canReturn =
                await background.invokeMethod<bool>('canBringToFront') ?? false;
            if (!canReturn) {
              return const CommandResult.fail(
                'Restarting needs the "Display over other apps" permission '
                'or the app cannot bring itself back.',
              );
            }
          }
          log.info('app', 'restarting application (agent mode)');
          try {
            await background.invokeMethod<void>('restartProcess', {
              'reason': 'restart requested (agent mode)',
            });
          } on PlatformException catch (e) {
            return CommandResult.fail('restart failed: $e');
          } on MissingPluginException {
            return const CommandResult.fail('restart is Android-only');
          }
          return const CommandResult.ok();
        },
      ),
    );
  }

  /// Opening another app is the kiosk manager's, and an agent is usually a
  /// box whose job is to run one: a projector told from Home Assistant to
  /// start Plezy or Kodi. The kiosk version wraps the same platform call in
  /// screen-pinning bookkeeping that has no meaning without a kiosk lock, so
  /// these are the plain calls. ESPHome already carries a launch_app action,
  /// which is what makes this reachable from an automation.
  @visibleForTesting
  void registerAgentAppCommands() {
    const background = MethodChannel('kiosk_satellite/background');
    commands.register(
      Command(
        name: 'launchApp',
        description:
            'Open another Android app by package name. Fails when the '
            'package is not installed or has nothing launchable.',
        params: const {'package': 'Android package, e.g. com.edde746.plezy'},
        handler: (p) async {
          final package = '${p['package'] ?? ''}'.trim();
          if (package.isEmpty) return const CommandResult.fail('package required');
          try {
            final ok =
                await background.invokeMethod<bool>('launchApp', {
                  'package': package,
                }) ??
                false;
            return ok
                ? const CommandResult.ok()
                : CommandResult.fail(
                    '$package is not installed, or has no app to open',
                  );
          } on MissingPluginException {
            return const CommandResult.fail('opening apps is Android-only');
          } on PlatformException catch (e) {
            return CommandResult.fail('could not open the app: $e');
          }
        },
      ),
    );
    commands.register(
      Command(
        name: 'openUri',
        description:
            'Open a deep link or custom URI with whatever app claims it - '
            'the precise way to start a player on a particular thing.',
        params: const {'uri': 'URI to open, e.g. plezy://item/123'},
        handler: (p) async {
          final uri = '${p['uri'] ?? ''}'.trim();
          if (uri.isEmpty) return const CommandResult.fail('uri required');
          try {
            final ok =
                await background.invokeMethod<bool>('openUri', {'uri': uri}) ??
                false;
            return ok
                ? const CommandResult.ok()
                : CommandResult.fail('nothing on this device opens $uri');
          } on MissingPluginException {
            return const CommandResult.fail('opening a URI is Android-only');
          } on PlatformException catch (e) {
            return CommandResult.fail('could not open the URI: $e');
          }
        },
      ),
    );
  }

  /// The managers this container will actually start, for the agent-mode
  /// test: the list is a contract about what a device stops doing, and a
  /// regression there is silent on a box nobody looks at.
  @visibleForTesting
  List<Manager> get managersForTest => _ordered;

  Future<void> init() async {
    await settings.init();
    // Apply any adb/MDM intent provisioning before other managers read
    // their settings; the channel also handles pushes while running.
    await ProvisioningChannel(settings, log).init();
    await device.init();
    if (!agentMode) {
      jsApi = JsApiManager(bus, commands, log, device.appVersion)
        ..isTrustedOrigin = _isConfiguredOrigin
        ..isTheaterFrameOrigin = _isTheaterFrameOrigin;
      _jsApiBuilt = true;
    }
    for (final manager in _ordered.skip(2)) {
      await manager.init();
    }
    if (agentMode) {
      registerAgentRestart();
      registerAgentAppCommands();
    }
    log.info('app', 'all managers initialized');
  }

  /// Whether [origin] is a page this kiosk was pointed at, for the JS
  /// bridge's microphone methods: Home Assistant, the start URL, or the
  /// loopback proxy that serves either one as a secure context. Read from
  /// the settings on every call, so changing the URL needs no re-wiring.
  /// Whether a frame at [origin] is the page the "Page allowed from a
  /// frame" setting names: same scheme, host and port, nothing looser.
  bool _isTheaterFrameOrigin(Uri origin) =>
      isSameWebOrigin(settings.get(defs.theaterFrameUrl), origin);

  bool _isConfiguredOrigin(Uri origin) {
    bool same(String configured) {
      final uri = Uri.tryParse(configured.trim());
      return uri != null &&
          uri.host.isNotEmpty &&
          uri.scheme == origin.scheme &&
          uri.host.toLowerCase() == origin.host.toLowerCase() &&
          uri.port == origin.port;
    }

    final loopback = proxy.loopbackOrigin;
    return same(settings.get(defs.haUrl)) ||
        same(settings.get(defs.startUrl)) ||
        (loopback != null && same(loopback));
  }

  Future<void> dispose() async {
    for (final manager in _ordered.reversed) {
      await manager.dispose();
    }
    await log.dispose();
    await bus.dispose();
  }
}
