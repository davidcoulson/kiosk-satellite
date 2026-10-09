import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/home_assistant/entity_list.dart';
import 'package:kiosk_satellite/ui/entity_picker.dart';

/// The entity list's filters (issue #911 and the entity picker): a picker
/// opens on what its setting takes, light level sensors for adaptive
/// brightness, listed as it opens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const entities = <Map<String, Object?>>[
    {
      'entity_id': 'sensor.kitchen_illuminance',
      'name': 'Kitchen illuminance',
      'state': '83 lx',
      'domain': 'sensor',
      'device_class': 'illuminance',
      'unit': 'lx',
    },
    {
      'entity_id': 'sensor.porch_light_level',
      'name': 'Porch light level',
      'state': '1200 lx',
      'domain': 'sensor',
      'unit': 'lx',
    },
    {
      'entity_id': 'sensor.kitchen_temperature',
      'name': 'Kitchen temperature',
      'state': '21 °C',
      'domain': 'sensor',
      'device_class': 'temperature',
      'unit': '°C',
    },
    {
      'entity_id': 'light.kitchen',
      'name': 'Kitchen light',
      'state': 'On',
      'domain': 'light',
    },
  ];

  List<String> ids(List<Map<String, Object?>> list) => [
    for (final e in list) '${e['entity_id']}',
  ];

  test('the illuminance filter keeps the class and readings in lux', () {
    expect(ids(filterEntities(entities, deviceClass: 'illuminance')), [
      'sensor.kitchen_illuminance',
      'sensor.porch_light_level',
    ]);
  });

  test('a domain filter keeps that domain, none keeps all', () {
    expect(ids(filterEntities(entities, domains: ['light'])), [
      'light.kitchen',
    ]);
    expect(filterEntities(entities), hasLength(4));
  });

  test('states and domains read well without Home Assistant formatting', () {
    expect(formatStateFallback('21.5', '°C'), '21.5 °C');
    expect(formatStateFallback('above_horizon', null), 'Above horizon');
    expect(domainTitleFallback('binary_sensor'), 'Binary sensor');
    expect(defaultEntityIcon('sensor', 'temperature'), 'mdi:thermometer');
    expect(defaultEntityIcon('binary_sensor', 'door'), 'mdi:door');
    expect(defaultEntityIcon('light', null), 'mdi:lightbulb');
  });

  testWidgets('a light sensor picker lists only light level sensors, '
      'before anything is typed', (tester) async {
    PickCatalog.reset();
    final commands = CommandRegistry(Logger());
    commands.register(
      Command(
        name: 'haListEntities',
        description: 'fake',
        handler: (_) async => const CommandResult.ok(entities),
      ),
    );
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showItemPicker(
              context,
              title: 'Light sensor entity',
              spec: entitySpec(context, commands, deviceClass: 'illuminance'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Kitchen illuminance'), findsOneWidget);
    expect(find.text('Porch light level'), findsOneWidget);
    expect(find.text('Kitchen temperature'), findsNothing);
    expect(find.text('Kitchen light'), findsNothing);
  });

  test('a service keeps the entity domains its target names', () {
    expect(serviceEntityDomains({}), isNull);
    expect(serviceEntityDomains({'target': {}}), isEmpty);
    expect(
      serviceEntityDomains({
        'target': {
          'entity': [
            {
              'domain': ['light'],
            },
            {
              'domain': ['switch', 'light'],
            },
          ],
        },
      }),
      unorderedEquals(['light', 'switch']),
    );
    // A filter by integration alone reaches any domain.
    expect(
      serviceEntityDomains({
        'target': {
          'entity': [
            {
              'domain': ['light'],
            },
            {'integration': 'hue'},
          ],
        },
      }),
      isEmpty,
    );
  });

  test('services are named by translation, then the server, then the id', () {
    final rows = serviceRows(
      {
        'light': {
          'turn_on': {
            'name': 'Turn on',
            'target': {
              'entity': [
                {
                  'domain': ['light'],
                },
              ],
            },
          },
          'toggle': {'name': 'Toggle'},
        },
        'homeassistant': {'reload_all': {}},
        'script': {'good_morning': {}},
        'automation': {'trigger': {}},
      },
      names: {'light.toggle': 'Umschalten'},
      titles: {'light': 'Licht'},
    );
    final byId = {for (final r in rows) r['id']: r};
    expect(byId['light.turn_on']!['name'], 'Turn on');
    expect(byId['light.turn_on']!['entity_domains'], ['light']);
    expect(byId['light.toggle']!['name'], 'Umschalten');
    expect(byId['light.toggle']!['domain_title'], 'Licht');
    expect(byId['light.toggle']!['entity_domains'], isNull);
    expect(byId['homeassistant.reload_all']!['name'], 'Reload all');
    expect(byId['homeassistant.reload_all']!['domain_title'], 'Homeassistant');
    // Scripts and automations have gestures of their own.
    expect(byId.keys.where((id) => '$id'.startsWith('script.')), isEmpty);
    expect(byId.keys.where((id) => '$id'.startsWith('automation.')), isEmpty);
  });

  test('a last used timestamp is not listed as a state', () {
    expect(
      withPickerState({'domain': 'tts', 'state': '2026-10-08T22:53:00'}),
      containsPair('state', null),
    );
    expect(
      withPickerState({'domain': 'light', 'state': 'On'}),
      containsPair('state', 'On'),
    );
  });
}
