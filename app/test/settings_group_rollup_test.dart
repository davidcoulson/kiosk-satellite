import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Rolled-up rail groups: the sibling of hidden pages. Hiding a page is a
/// decision about this panel; rolling up a group is a view of the list, so
/// a rolled-up group stays one tap from open and nothing leaves the table.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsManager settings;

  Future<void> build([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    final bus = EventBus();
    final log = Logger();
    settings = SettingsManager(bus, CommandRegistry(log), log);
    await settings.init();
  }

  test('nothing is rolled up until someone rolls it up', () async {
    await build();
    expect(settings.get(defs.uiCollapsedGroups), '[]');
    expect(defs.decodeStringSet(settings.get(defs.uiCollapsedGroups)), isEmpty);
  });

  test('a stored group survives a restart', () async {
    await build({
      'flutter.ks.ui.collapsed_groups': json.encode(['Display']),
    });
    expect(defs.decodeStringSet(settings.get(defs.uiCollapsedGroups)), {
      'Display',
    });
  });

  test('the value round-trips as a sorted JSON array', () async {
    await build();
    await settings.set(
      defs.uiCollapsedGroups,
      json.encode(['Media & Cameras', 'Display']..sort()),
    );
    expect(settings.get(defs.uiCollapsedGroups), '["Display","Media & Cameras"]');
    expect(defs.decodeStringSet(settings.get(defs.uiCollapsedGroups)), {
      'Display',
      'Media & Cameras',
    });
  });

  test('a malformed value reads as nothing rolled up, not a crash', () {
    // The list is read at render, on a wall panel. A value mangled by hand
    // or by a half-finished write must degrade to "everything open" rather
    // than throw somewhere nobody can see the stack trace.
    expect(defs.decodeStringSet('not json'), isEmpty);
    expect(defs.decodeStringSet('{"a":1}'), isEmpty);
    expect(defs.decodeStringSet('[1, 2, 3]'), isEmpty);
    expect(defs.decodeStringSet('["Display", 7]'), {'Display'});
  });

  test('the validator takes arrays of strings and refuses the rest', () {
    final validate = defs.uiCollapsedGroups.validator!;
    expect(validate(json.encode(<String>[])), isNull);
    expect(validate(json.encode(['Display', 'Network'])), isNull);
    expect(validate('[1]'), isNotNull);
    expect(validate('{}'), isNotNull);
    expect(validate('nonsense'), isNotNull);
  });

  test('rolling up hides nothing from the rest of the app', () async {
    // The point of the feature: unlike hidden pages, this is presentation
    // only. The definitions table is untouched, so search, Remote Admin and
    // the ESPHome catalogue all still see every setting in the group.
    await build();
    final before = defs.allSettings.length;
    await settings.set(defs.uiCollapsedGroups, json.encode(['Display']));
    expect(defs.allSettings.length, before);
    expect(
      defs.allSettings.any((d) => d.category == 'Screen & Audio'),
      isTrue,
    );
  });
}
