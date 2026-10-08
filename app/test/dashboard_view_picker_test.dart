import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/ui/dashboard_view_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _home = HaDashboard(
  path: 'lovelace',
  title: 'Overview',
  views: [
    HaView(title: 'Home', route: 'home'),
    HaView(title: 'Kitchen', route: 'kitchen'),
  ],
);
const _homeMore = HaDashboard(
  path: 'lovelace-more',
  title: 'More',
  views: [HaView(title: 'Kitchen', route: 'kitchen')],
);
const _map = HaDashboard(path: 'map', title: 'Map');

Future<AppContainer> _container({bool fail = false}) async {
  SharedPreferences.setMockInitialValues({});
  DashboardCatalog.reset();
  final c = AppContainer();
  await c.settings.init();
  c.commands
    ..register(
      Command(
        name: 'haListDashboards',
        description: 'stub',
        handler: (_) async => fail
            ? const CommandResult.fail('could not list dashboards')
            : const CommandResult.ok([
                {'url_path': 'wall', 'title': 'Wall', 'icon': 'mdi:tablet'},
                {'url_path': 'map', 'title': 'Map'},
              ]),
      ),
    )
    ..register(
      Command(
        name: 'haListDashboardViews',
        description: 'stub',
        handler: (p) async => CommandResult.ok(
          p['url_path'] == 'wall'
              ? [
                  {'title': 'Clock', 'route': 'clock', 'icon': 'mdi:clock'},
                  {'title': 'Weather', 'route': 'weather'},
                  {'title': 'Laundry', 'route': 'laundry', 'subview': true},
                ]
              : const [],
        ),
      ),
    );
  return c;
}

Future<void> _pump(
  WidgetTester tester,
  Size size,
  Widget Function(BuildContext) child,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Builder(builder: child)),
    ),
  );
}

void main() {
  test('a bare dashboard reads as its first view', () {
    final list = [_home, _homeMore, _map];
    final bare = DashboardCatalog.match(list, 'lovelace');
    expect(bare?.dashboard.path, 'lovelace');
    expect(bare?.view?.route, 'home');
    // A shared prefix is not a match: the slash ends the dashboard.
    expect(
      DashboardCatalog.match(list, 'lovelace-more/kitchen')?.dashboard.title,
      'More',
    );
    expect(DashboardCatalog.match(list, 'map')?.view, isNull);
    expect(DashboardCatalog.match(list, 'lovelace/gone'), isNull);
    expect(DashboardCatalog.match(list, ''), isNull);
  });

  test('the navigation path comes out of a start URL on the origin', () {
    const base = 'http://ha.local:8123';
    expect(dashboardPathOfUrl('$base/wall/clock?kiosk', base), 'wall/clock');
    expect(dashboardPathOfUrl('$base/wall/', base), 'wall');
    expect(dashboardPathOfUrl('https://elsewhere/wall', base), isNull);
  });

  testWidgets('the wide picker lists views as tiles and searches them', (
    tester,
  ) async {
    final c = await _container();
    String? picked = 'none';
    await _pump(
      tester,
      const Size(1200, 800),
      (context) => TextButton(
        onPressed: () async => picked = await showDashboardPicker(
          context,
          container: c,
          title: 'Dashboard view',
          selected: 'wall/clock',
        ),
        child: const Text('open'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Clock'), findsOneWidget);
    expect(find.text('Subviews'), findsOneWidget);
    expect(find.text('Builds its own views'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'wea');
    await tester.pumpAndSettle();
    expect(find.text('Clock'), findsNothing);
    expect(find.textContaining('ther'), findsWidgets);
    await tester.enterText(find.byType(TextField), 'nothing like it');
    await tester.pumpAndSettle();
    expect(find.text('No views match'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    // The dashboard that builds its own views offers itself whole.
    await tester.tap(find.text('Map').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Whole dashboard'));
    await tester.pumpAndSettle();
    expect(picked, 'map');
  });

  for (final size in const [Size(1200, 800), Size(400, 800)]) {
    testWidgets('Cancel closes the picker without a pick at $size', (
      tester,
    ) async {
      final c = await _container();
      String? picked = 'untouched';
      var closed = false;
      await _pump(
        tester,
        size,
        (context) => TextButton(
          onPressed: () async {
            picked = await showDashboardPicker(
              context,
              container: c,
              title: 'Dashboard view',
              selected: 'wall/clock',
            );
            closed = true;
          },
          child: const Text('open'),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(picked, isNull);
    });
  }

  testWidgets('the inline picker has nothing to cancel', (tester) async {
    final c = await _container();
    await _pump(
      tester,
      const Size(1200, 800),
      (_) => SizedBox(
        height: 460,
        child: DashboardPicker(container: c, onPick: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Clock'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('a phone drills from the dashboards into the views', (
    tester,
  ) async {
    final c = await _container();
    String? picked;
    await _pump(
      tester,
      const Size(400, 800),
      (context) => TextButton(
        onPressed: () async => picked = await showDashboardPicker(
          context,
          container: c,
          title: 'Dashboard view',
          selected: 'wall/clock',
        ),
        child: const Text('open'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Dashboards'), findsOneWidget);
    expect(find.text('Weather'), findsNothing);
    await tester.tap(find.text('Wall'));
    await tester.pumpAndSettle();
    expect(find.text('/wall'), findsOneWidget);
    await tester.tap(find.text('Weather'));
    await tester.pumpAndSettle();
    expect(picked, 'wall/weather');
  });

  testWidgets('several views come back in the order they were picked', (
    tester,
  ) async {
    final c = await _container();
    List<String>? picked;
    await _pump(
      tester,
      const Size(1200, 800),
      (context) => TextButton(
        onPressed: () async => picked = await showDashboardMultiPicker(
          context,
          container: c,
          title: 'Views to rotate',
          selected: const ['map', 'wall'],
        ),
        child: const Text('open'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    // It opens on the dashboard of the first pick.
    expect(find.text('Whole dashboard'), findsOneWidget);
    await tester.tap(find.text('Wall'));
    await tester.pumpAndSettle();
    // 'wall' alone is its first view, so unticking Clock drops it.
    await tester.tap(find.text('Clock'));
    await tester.tap(find.text('Weather'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(picked, ['map', 'wall/weather']);
  });

  testWidgets('an unreachable Home Assistant says so and offers a retry', (
    tester,
  ) async {
    final c = await _container(fail: true);
    await _pump(
      tester,
      const Size(1200, 800),
      (context) => TextButton(
        onPressed: () =>
            showDashboardPicker(context, container: c, title: 'Dashboard view'),
        child: const Text('open'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Could not reach Home Assistant'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a stored view gone from Home Assistant is flagged', (
    tester,
  ) async {
    final c = await _container();
    await DashboardCatalog.load(c);
    await _pump(
      tester,
      const Size(1200, 800),
      (_) => DashboardViewRow(
        container: c,
        title: 'Dashboard view',
        value: 'wall/patio',
        onPick: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('wall/patio'), findsOneWidget);
    expect(
      find.text('This view is gone from Home Assistant. Choose another.'),
      findsOneWidget,
    );
  });
}
