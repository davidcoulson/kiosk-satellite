import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/ui/agent_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The agent's status card: the remote admin address is the one thing worth
/// reading off a projector, so it is also a QR code a phone can open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppContainer> build({required bool remote, bool tls = false}) async {
    SharedPreferences.setMockInitialValues({
      'flutter.ks.device.agent_mode': true,
      'flutter.ks.${defs.remoteEnabled.key}': remote,
      'flutter.ks.${defs.remoteTls.key}': tls,
    });
    final c = AppContainer();
    await c.settings.init();
    c.commands.register(
      Command(
        name: 'getDeviceInfo',
        description: 'test',
        handler: (_) async =>
            const CommandResult.ok({'ip': '10.2.1.29', 'appVersion': 'test'}),
      ),
    );
    return c;
  }

  Future<void> show(WidgetTester tester, AppContainer c) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AgentScreen(container: c)));
    await tester.pump();
  }

  String url(AppContainer c, String scheme) =>
      '$scheme://10.2.1.29:${c.settings.get(defs.remotePort)}';

  testWidgets('the admin address is also a QR code', (tester) async {
    final c = await build(remote: true);
    await show(tester, c);
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr.semanticsLabel, 'Remote admin: ${url(c, 'http')}');
    expect(find.text(url(c, 'http')), findsOneWidget);
  });

  testWidgets('an HTTPS admin gets an https link', (tester) async {
    final c = await build(remote: true, tls: true);
    await show(tester, c);
    expect(
      tester.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel,
      'Remote admin: ${url(c, 'https')}',
    );
  });

  testWidgets('no QR code while the remote admin is off', (tester) async {
    final c = await build(remote: false);
    await show(tester, c);
    expect(find.byType(QrImageView), findsNothing);
  });
}
