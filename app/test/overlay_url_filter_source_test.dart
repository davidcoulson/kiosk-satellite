import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The external-page overlay's WebView cannot be built in a widget test, so
// this pins the wiring that keeps its URL Filter state live across settings
// changes and navigation.
void main() {
  test(
    'overlay re-reads the URL Filter and swaps its document-start script',
    () {
      final src = File('lib/ui/kiosk_screen.dart').readAsStringSync();
      expect(src, contains('late bool _filtered = _externalRules();'));
      expect(src, contains('unawaited(_applyFilter(controller));'));
      expect(src, contains('useShouldOverrideUrlLoading: _filtered'));
      expect(
        src,
        contains('removeUserScriptsByGroupName(groupName: _filterGroup)'),
      );
      // The seed script uses the same group, so the swap replaces it.
      expect(src, contains('groupName: _filterGroup,'));
    },
  );
}
