import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart';
import 'package:kiosk_satellite/ui/entity_picker.dart';
import 'package:kiosk_satellite/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Now Playing page's Filter the speaker selection pill row (issue
/// #974): the picks by name, All speakers with none, no row for a source
/// without a menu, and one picker over Music Assistant's players and the
/// Sonos rooms with a chip per source. Mirrored on the remote (rows.js).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppContainer> open(
    WidgetTester tester, {
    String source = '',
    List<String> picks = const [],
    bool sonos = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'ks.sendspin.enabled': true,
      'ks.sendspin.player_active': true,
      'ks.sendspin.fullscreen': true,
      'ks.sendspin.player_source': source,
      'ks.sendspin.player': '',
      'ks.sendspin.speaker_pill_players': jsonEncode(picks),
    });
    PickCatalog.reset();
    final container = AppContainer();
    await container.settings.init();
    if (!container.commands.all.any((c) => c.name == 'mediaPlayers')) {
      container.commands.register(
        Command(
          name: 'mediaPlayers',
          description: 'fake',
          handler: (p) async => CommandResult.ok({
            'players': [
              {'id': 'ma:kitchen', 'name': 'Kitchen', 'group': 'ma'},
              {'id': 'ma:office', 'name': 'Office', 'group': 'ma'},
              if (sonos && p['rooms'] == true) ...[
                {'id': 'sonos:RINCON_A', 'name': 'Den', 'group': 'sonos'},
                {'id': 'sonos:RINCON_B', 'name': 'Patio', 'group': 'sonos'},
              ],
            ],
            'notes': {if (!sonos) 'sonos': 'No Sonos speakers known yet.'},
          }),
        ),
      );
    }
    tester.view.physicalSize = const Size(500, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(container: container)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    for (final title in ['Media Player', 'Now Playing']) {
      await tester.tap(find.text(title).first);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
    }
    return container;
  }

  testWidgets('no picks offer every speaker', (tester) async {
    await open(tester);
    expect(find.text('Filter the speaker selection pill'), findsOneWidget);
    expect(find.text('All speakers'), findsOneWidget);
  });

  testWidgets('the picks of every source show by name', (tester) async {
    await open(tester, picks: ['ma:kitchen', 'sonos:RINCON_A']);
    expect(find.text('Kitchen, Den'), findsOneWidget);
  });

  testWidgets('a Home Assistant player has no menu, so no row', (tester) async {
    await open(tester, source: 'ha');
    expect(find.text('Show speaker selection pill'), findsOneWidget);
    expect(find.text('Filter the speaker selection pill'), findsNothing);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  testWidgets('one picker lists both sources, a chip for each', (tester) async {
    final container = await open(tester, picks: ['ma:kitchen']);
    await tester.tap(find.text('Kitchen'));
    await settle(tester);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Music Assistant'), findsWidgets);
    expect(find.text('Patio'), findsOneWidget);
    // The Sonos chip shows its rooms alone.
    await tester.tap(find.text('Sonos').first);
    await settle(tester);
    expect(find.text('Office'), findsNothing);
    await tester.tap(find.text('Patio'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(
      decodeSpeakerPillPlayers(
        container.settings.get(sendspinSpeakerPillPlayers),
      ),
      ['ma:kitchen', 'sonos:RINCON_B'],
    );
    expect(find.text('Kitchen, Patio'), findsOneWidget);
  });

  testWidgets('without Sonos the list is plain', (tester) async {
    await open(tester, sonos: false);
    await tester.tap(find.text('All speakers'));
    await settle(tester);
    expect(find.text('Office'), findsOneWidget);
    expect(find.text('All'), findsNothing);
    expect(find.text('Music Assistant'), findsNothing);
    expect(find.textContaining('No Sonos speakers'), findsNothing);
  });
}
