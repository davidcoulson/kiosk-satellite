import 'core/command_registry.dart';
import 'core/event_bus.dart';
import 'core/logging.dart';
import 'core/manager.dart';
import 'managers/plugins/plugin_manager.dart';
import 'managers/assist_pipeline/assist_pipeline_manager.dart';
import 'managers/audio/audio_routing_manager.dart';
import 'managers/browser/browser_manager.dart';
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
import 'managers/settings/settings_manager.dart';
import 'managers/update/update_manager.dart';
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
    immich = ImmichManager(bus, commands, log, settings);
    // Before motion: its init runs the legacy motion-camera migration the
    // motion manager's gate reads.
    deviceCamera = DeviceCameraManager(bus, commands, log, settings);
    motion = MotionManager(bus, commands, log, settings);
    proximity = ProximityManager(bus, commands, log, settings);
    location = LocationManager(bus, commands, log, settings);
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
    sound = SoundManager(bus, commands, log);
    notifications = NotificationManager(bus, commands, log, settings);
    update = UpdateManager(bus, commands, log);
    // After homeAssistant: it reads states through it for the fallback.
    glance = GlanceManager(bus, commands, log, settings, homeAssistant);
    plugins = PluginManager(bus, commands, log);
    remote = RemoteManager(bus, commands, log, settings);
    fleet = FleetManager(bus, commands, log, settings);
    fleetSync = FleetSyncManager(bus, commands, log, settings);
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
  late final ImmichManager immich;
  late final DeviceCameraManager deviceCamera;
  late final MotionManager motion;
  late final ProximityManager proximity;
  late final LocationManager location;
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
  late final NotificationManager notifications;
  late final UpdateManager update;
  late final PluginManager plugins;
  late final RemoteManager remote;
  late final FleetManager fleet;
  late final FleetSyncManager fleetSync;

  /// Built after [device.init] so it can carry the app version.
  late final JsApiManager jsApi;

  /// Managers the dashboard's first paint actually depends on: which
  /// origin the WebView loads (proxy), the WebView itself (browser), the
  /// bridge its page calls into (jsApi), and the on-screen lock/immersive
  /// behavior (kiosk). [init] awaits exactly these, in this order, so
  /// `runApp` never waits on a manager the first frame does not need.
  List<Manager> get _critical => [
    settings,
    device,
    screen,
    proxy,
    browser,
    jsApi,
    kiosk,
  ];

  /// Everything else: voice, cameras, sensors, casting, plugins, the
  /// remote admin server, fleet — real features, none of which gate the
  /// dashboard appearing. [initDeferred] brings these up, in this same
  /// relative order, after the UI is already on screen; the ordering
  /// notes below (which all concern managers within this list, or this
  /// list against [_critical]) still hold exactly as before the split.
  List<Manager> get _deferred => [
    service,
    camera,
    // After kiosk: it listens for the AppLaunched its launchApp emits,
    // and its bringToFront/screenOn calls resolve at execute time.
    launcher,
    // Same placement logic: its role relays arrive as bus events KioskManager
    // forwards, and its acquire path invokes the kiosk_lock channel.
    homeLauncher,
    screensaver,
    immich,
    deviceCamera,
    motion,
    proximity,
    location,
    personSensor,
    homeAssistant,
    audio,
    // After audio: gestures may open the shared microphone for clap
    // detection at init, and the capture selector and tuning must be
    // seeded first. Commands resolve at execute time, so running late
    // costs nothing.
    gestures,
    wakeWord,
    pipeline,
    sendspin,
    dlna,
    btProxy,
    files,
    glance,
    sound,
    notifications,
    update,
    plugins,
    remote,
    // After remote: it announces the admin server the remote manager runs.
    fleet,
    // After fleet: it reads this kiosk's id and the others from it.
    fleetSync,
  ];

  List<Manager> get _ordered => [..._critical, ..._deferred];

  /// Brings up the managers the dashboard's first paint depends on. Returns
  /// as soon as the WebView can safely be shown; the caller runs
  /// [initDeferred] right after `runApp` to bring the rest of the app up
  /// in the background, so a slow or idle feature never delays that first
  /// frame.
  Future<void> init() async {
    await settings.init();
    // Apply any adb/MDM intent provisioning before other managers read
    // their settings; the channel also handles pushes while running.
    await ProvisioningChannel(settings, log).init();
    await device.init();
    jsApi = JsApiManager(bus, commands, log, device.appVersion);
    for (final manager in _critical.skip(2)) {
      await manager.init();
    }
    log.info('app', 'critical managers initialized');
  }

  /// Brings up every manager not on the dashboard's critical path. Not
  /// part of [init]: call this after `runApp` so DLNA, Bluetooth proxy,
  /// fleet discovery, the remote admin server, plugins, wake word and the
  /// rest start in the background instead of gating the first frame.
  Future<void> initDeferred() async {
    for (final manager in _deferred) {
      await manager.init();
    }
    log.info('app', 'all managers initialized');
  }

  Future<void> dispose() async {
    for (final manager in _ordered.reversed) {
      await manager.dispose();
    }
    await log.dispose();
    await bus.dispose();
  }
}
