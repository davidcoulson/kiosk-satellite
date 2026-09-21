import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/managers/theater/theater_manager.dart';
import 'package:kiosk_satellite/ui/lockdown_shield.dart';
import 'package:kiosk_satellite/ui/theater_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The layer over the display. A finger landing on a button in the dark must
/// press nothing -- not a tap, not the start of a scroll -- and once the
/// panel is awake every touch must reach the page (T-53). The lockdown
/// shield still sits above it and still owns every touch (T-52).
void main() {
  late TheaterManager theater;
  late int pageTaps;
  late int pageDrags;

  Future<void> build(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    bool lockdown = false,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    for (final name in ['holdBrightness', 'releaseBrightness']) {
      commands.register(
        Command(
          name: name,
          description: 'fake',
          handler: (_) async => const CommandResult.ok(),
        ),
      );
    }
    final settings = SettingsManager(bus, commands, log);
    await settings.init();
    theater = TheaterManager(bus, commands, log, settings);
    await theater.init();
    pageTaps = 0;
    pageDrags = 0;
    // The same order as the kiosk screen: page, theater layer, shield.
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const Key('page'),
              behavior: HitTestBehavior.opaque,
              onTap: () => pageTaps++,
              onVerticalDragStart: (_) => pageDrags++,
              child: const ColoredBox(color: Colors.white),
            ),
            TheaterOverlay(theater: theater),
            if (lockdown) const LockdownShield(),
          ],
        ),
      ),
    );
  }

  Color? wash(WidgetTester tester) {
    final boxes = tester
        .widgetList<ColoredBox>(
          find.descendant(
            of: find.byType(TheaterOverlay),
            matching: find.byType(ColoredBox),
          ),
        )
        .toList();
    return boxes.isEmpty ? null : boxes.single.color;
  }

  testWidgets('off, the layer is not there and touches reach the page', (
    tester,
  ) async {
    await build(tester);
    await tester.tap(find.byKey(const Key('page')));
    expect(pageTaps, 1);
    expect(wash(tester), isNull);
  });

  testWidgets('dimmed, the first tap reaches nothing and wakes the panel; '
      'the next one presses', (tester) async {
    await build(tester);
    await theater.activate(const {}, source: 'page');
    await tester.pumpAndSettle();
    expect(wash(tester)!.a, closeTo(0.6, 0.01), reason: 'the default dimming');

    await tester.tap(find.byKey(const Key('page')));
    await tester.pumpAndSettle();
    expect(pageTaps, 0, reason: 'absorbed');
    expect(theater.phase, TheaterPhase.peek);
    expect(wash(tester), isNull, reason: 'no layer while peeking');

    await tester.tap(find.byKey(const Key('page')));
    expect(pageTaps, 1);
    await theater.deactivate(source: 'page');
    await tester.pumpAndSettle();
  });

  testWidgets('dimmed, a drag starting in the dark is not a scroll either', (
    tester,
  ) async {
    await build(tester);
    await theater.activate(const {}, source: 'page');
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('page')), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(pageDrags, 0);
    expect(theater.phase, TheaterPhase.peek);
    await theater.deactivate(source: 'page');
    await tester.pumpAndSettle();
  });

  testWidgets('with the first touch set to pass through, it presses and '
      'still wakes', (tester) async {
    await build(tester, prefs: {'ks.theater.first_touch_wakes': false});
    await theater.activate(const {}, source: 'page');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('page')));
    await tester.pumpAndSettle();
    expect(pageTaps, 1);
    expect(theater.phase, TheaterPhase.peek);
    await theater.deactivate(source: 'page');
    await tester.pumpAndSettle();
  });

  testWidgets('black is an opaque wash', (tester) async {
    await build(tester, prefs: {'ks.theater.black_after_minutes': 5});
    await theater.activate(const {}, source: 'page');
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(theater.phase, TheaterPhase.black);
    expect(wash(tester)!.a, closeTo(1, 0.01));
    await theater.deactivate(source: 'page');
    await tester.pumpAndSettle();
  });

  testWidgets('T-52 the lockdown shield sits above it and owns the touch', (
    tester,
  ) async {
    await build(tester, lockdown: true);
    await theater.activate(const {}, source: 'page');
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byKey(const Key('page'))));
    await tester.pumpAndSettle();
    expect(pageTaps, 0);
    // The shield took it, so theater mode never saw a touch.
    expect(theater.phase, TheaterPhase.dim);
    // Turning theater mode off leaves Lockdown exactly as it was.
    await theater.deactivate(source: 'page');
    await tester.pumpAndSettle();
    expect(find.byType(LockdownShield), findsOneWidget);
  });
}
