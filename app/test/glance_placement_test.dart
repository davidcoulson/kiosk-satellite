import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/ui/screensaver_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Issue #916: the At a Glance row ran into the Immich metadata in the
/// bottom corners of a small screen. It now wraps into the room the
/// panels leave, or rises above them when two chips do not fit there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({double bottom, double maxWidth, bool narrow}) place({
    bool narrow = true,
    List<Size> corners = const [],
    double compact = 400,
  }) => glancePlacement(
    width: 960,
    inset: 36,
    narrow: narrow,
    corners: corners,
    compactWidth: () => compact,
  );

  test('without bottom panels the row stays where it was', () {
    expect(place(narrow: false, corners: const [Size(300, 200)]), (
      bottom: 36,
      maxWidth: 960,
      narrow: false,
    ));
  });

  test('before the panels are measured the row wraps narrow', () {
    expect(place(), (bottom: 36, maxWidth: 960, narrow: true));
  });

  test('the row wraps into the room between the panels', () {
    // 960 less two 250-wide panels leaves 460, enough for 400.
    expect(place(corners: const [Size(250, 180), Size(200, 150)]), (
      bottom: 36,
      maxWidth: 460,
      narrow: true,
    ));
  });

  test('the wider panel sets the room on both sides', () {
    // The row is centred, so one 300-wide panel leaves 360 either way.
    expect(place(corners: const [Size(300, 180)]).narrow, isFalse);
  });

  test('a row too wide for the room rises above the taller panel', () {
    expect(place(corners: const [Size(300, 150), Size(280, 190)]), (
      bottom: 190,
      maxWidth: 960,
      narrow: false,
    ));
  });

  group('metadata footprint', () {
    late AppContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      container = AppContainer();
      await container.settings.init();
    });

    test('keeps the largest panel seen in each corner', () {
      final screensaver = container.screensaver;
      screensaver.reportMetadataFootprint('bottom_left', const Size(250, 150));
      screensaver.reportMetadataFootprint('bottom_left', const Size(200, 190));
      screensaver.reportMetadataFootprint('bottom_right', const Size(180, 120));
      expect(screensaver.metadataFootprint.value, {
        'bottom_left': const Size(250, 190),
        'bottom_right': const Size(180, 120),
      });
    });

    test('a smaller panel changes nothing', () {
      final screensaver = container.screensaver;
      screensaver.reportMetadataFootprint('bottom_left', const Size(250, 150));
      var notified = 0;
      screensaver.metadataFootprint.addListener(() => notified++);
      screensaver.reportMetadataFootprint('bottom_left', const Size(240, 140));
      expect(notified, 0);
    });
  });
}
