import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/ui/text_snapshot.dart';

/// The snapshot that keeps shadowed text cheap on Weather Mood.
///
/// What is pinned here is that new content retakes the image without
/// rebuilding the child from scratch: an At a Glance chip that was
/// remounted on every state change started its icon over at the fallback,
/// and the snapshot kept that fallback for good (issue #979).
void main() {
  Widget host(Object content) => MaterialApp(
    home: Center(
      child: TextSnapshot(content: content, bleed: 4, child: const _Probe()),
    ),
  );

  testWidgets('new content keeps the child mounted', (tester) async {
    _Probe.mounts = 0;
    await tester.pumpWidget(host(('Door', 'Closed')));
    await tester.pumpWidget(host(('Door', 'Open')));
    await tester.pumpWidget(host(('Door', 'Closed')));
    expect(_Probe.mounts, 1);
  });

  testWidgets(
    'a child can ask for a new image, and outside one it is a no-op',
    (tester) async {
      await tester.pumpWidget(host('a'));
      TextSnapshot.refresh(tester.element(find.byType(_Probe)));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const MaterialApp(home: _Probe()));
      TextSnapshot.refresh(tester.element(find.byType(_Probe)));
      expect(tester.takeException(), isNull);
    },
  );
}

class _Probe extends StatefulWidget {
  const _Probe();

  static int mounts = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 20, height: 20);
}
