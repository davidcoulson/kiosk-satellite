import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/btproxy/bt_proxy_manager.dart';

/// The two settings are kept apart so a backup can carry the thresholds
/// without carrying the keys, which means something has to put them back
/// together — and get it right when either side is empty or nonsense,
/// because both are text fields a person types into.
void main() {
  test('a filter with no keys passes through unchanged', () {
    final out = jsonDecode(mergedAdvertisementFilter('{"rssiThreshold":-60}', ''));
    expect(out, {'rssiThreshold': -60});
  });

  test('keys are merged into the filter the scanner receives', () {
    final out = jsonDecode(mergedAdvertisementFilter(
      '{"rssiThreshold":-60}',
      '["ec0234a357c8ad05341010a60a397d9b"]',
    ));
    expect(out['rssiThreshold'], -60);
    expect(out['irks'], ['ec0234a357c8ad05341010a60a397d9b']);
  });

  test('keys alone are a filter, with no thresholds set', () {
    final out = jsonDecode(
      mergedAdvertisementFilter('', '["ec0234a357c8ad05341010a60a397d9b"]'),
    );
    expect(out, {
      'irks': ['ec0234a357c8ad05341010a60a397d9b'],
    });
  });

  test('both empty means no filter at all, not an empty one', () {
    // The difference matters: an empty object still counts as configured
    // downstream, and a panel that filters nothing should not pay for a
    // filter it does not have.
    expect(mergedAdvertisementFilter('', ''), '');
    expect(mergedAdvertisementFilter('{}', ''), '');
  });

  test('a malformed filter does not drop everything', () {
    // Nonsense in a text field must not become a filter that silently
    // stops the panel reporting anything.
    expect(mergedAdvertisementFilter('not json', ''), '');
    final out = jsonDecode(
      mergedAdvertisementFilter('not json', '["ec0234a357c8ad05341010a60a397d9b"]'),
    );
    expect(out['irks'], hasLength(1));
  });

  test('keys pasted as plain lines are accepted, not silently ignored', () {
    // A key list copied out of Home Assistant arrives one per line far more
    // often than as JSON.
    final out = jsonDecode(mergedAdvertisementFilter(
      '',
      'ec0234a357c8ad05341010a60a397d9b\n11112222333344445555666677778888',
    ));
    expect(out['irks'], hasLength(2));
  });
}
