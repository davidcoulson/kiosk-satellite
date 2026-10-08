import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/home_assistant/home_assistant_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/ui/entity_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The entity search's illuminance filter (issue #911): adaptive
/// brightness's entity picker offers light level sensors only, listed as
/// it opens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const states = [
    {
      'entity_id': 'sensor.kitchen_illuminance',
      'state': '83',
      'attributes': {
        'friendly_name': 'Kitchen illuminance',
        'device_class': 'illuminance',
        'unit_of_measurement': 'lx',
      },
    },
    {
      'entity_id': 'sensor.porch_light_level',
      'state': '1200',
      'attributes': {
        'friendly_name': 'Porch light level',
        'unit_of_measurement': 'lx',
      },
    },
    {
      'entity_id': 'sensor.kitchen_temperature',
      'state': '21',
      'attributes': {
        'friendly_name': 'Kitchen temperature',
        'device_class': 'temperature',
        'unit_of_measurement': '°C',
      },
    },
    {
      'entity_id': 'light.kitchen',
      'state': 'on',
      'attributes': {'friendly_name': 'Kitchen light'},
    },
  ];

  Future<List<String>?> search(String query, {String? filter}) async {
    SharedPreferences.setMockInitialValues({
      'ks.ha.url': 'http://ha.local:8123',
      'ks.ha.token': 'token',
    });
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    final settings = SettingsManager(bus, commands, log);
    await settings.init();
    final ha = HomeAssistantManager(bus, commands, log, settings);
    final matches = await http.runWithClient(
      () => ha.searchEntities(query, filter: filter),
      () => MockClient((_) async => http.Response(jsonEncode(states), 200)),
    );
    return matches?.map((m) => '${m['entity_id']}').toList();
  }

  test('the filter keeps the illuminance class and readings in lux', () async {
    expect(await search('', filter: 'illuminance'), [
      'sensor.kitchen_illuminance',
      'sensor.porch_light_level',
    ]);
    expect(await search('kitchen', filter: 'illuminance'), [
      'sensor.kitchen_illuminance',
    ]);
  });

  test('without the filter the search is unchanged', () async {
    expect(await search('kitchen'), [
      'sensor.kitchen_illuminance',
      'light.kitchen',
      'sensor.kitchen_temperature',
    ]);
  });

  testWidgets('a filtered picker lists its entities before anything is '
      'typed', (tester) async {
    final commands = CommandRegistry(Logger());
    final asked = <Map<String, Object?>>[];
    commands.register(
      Command(
        name: 'haSearchEntities',
        description: 'fake',
        handler: (p) async {
          asked.add(Map.of(p));
          return const CommandResult.ok([
            {
              'entity_id': 'sensor.kitchen_illuminance',
              'name': 'Kitchen illuminance',
              'state': '83',
            },
          ]);
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickHomeAssistantEntityFromCommands(
              context,
              commands,
              title: 'Light sensor entity',
              filter: 'illuminance',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(asked, [
      {'query': '', 'filter': 'illuminance'},
    ]);
    expect(find.text('Kitchen illuminance'), findsOneWidget);
  });
}
