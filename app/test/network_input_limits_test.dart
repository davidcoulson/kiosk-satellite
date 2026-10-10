// Limits on what a device on the network can make the kiosk hold or do:
// the capped reader behind image downloads, DLNA event callbacks and the
// SOAP argument parser.
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/capped_read.dart';
import 'package:kiosk_satellite/managers/dlna/dlna_manager.dart';
import 'package:kiosk_satellite/managers/dlna/upnp_xml.dart';

void main() {
  group('readCapped', () {
    Stream<List<int>> chunks(int n, int size) =>
        Stream.fromIterable(List.generate(n, (_) => List.filled(size, 7)));

    test('reads a body within the cap whole', () async {
      expect((await readCapped(chunks(4, 10), 40)).length, 40);
    });

    test('stops at the cap instead of holding everything first', () async {
      var pulled = 0;
      final endless = Stream<List<int>>.periodic(Duration.zero, (_) {
        pulled++;
        return List.filled(1024, 0);
      });
      await expectLater(readCapped(endless, 8 * 1024), throwsStateError);
      expect(pulled, lessThan(20));
    });
  });

  group('DLNA event callbacks', () {
    test('go back to the subscriber only, over http', () {
      expect(
        dlnaCallbackAllowed(Uri.parse('http://10.0.0.8:49152/evt'), '10.0.0.8'),
        isTrue,
      );
      expect(
        dlnaCallbackAllowed(
          Uri.parse('http://10.0.0.8:49152/evt'),
          '::ffff:10.0.0.8',
        ),
        isTrue,
      );
      // Aimed at another host, or at the kiosk's own services.
      expect(
        dlnaCallbackAllowed(Uri.parse('http://10.0.0.9/evt'), '10.0.0.8'),
        isFalse,
      );
      expect(
        dlnaCallbackAllowed(Uri.parse('http://127.0.0.1:2324/x'), '10.0.0.8'),
        isFalse,
      );
      expect(
        dlnaCallbackAllowed(Uri.parse('https://10.0.0.8/evt'), '10.0.0.8'),
        isFalse,
      );
      expect(dlnaCallbackAllowed(Uri.parse('http://10.0.0.8/'), null), isFalse);
    });
  });

  group('parseSoapArgs', () {
    test('reads an ordinary control call', () {
      const body =
          '<s:Envelope><s:Body><u:SetAVTransportURI>'
          '<InstanceID>0</InstanceID><CurrentURI>http://x/a.mp3</CurrentURI>'
          '</u:SetAVTransportURI></s:Body></s:Envelope>';
      expect(parseSoapArgs(body), {
        'InstanceID': '0',
        'CurrentURI': 'http://x/a.mp3',
      });
    });

    test('stops following nested markup past its depth', () {
      // Distinct names at each level, so each one is a real nesting step.
      final open = [for (var i = 0; i < 50; i++) '<t$i>'].join();
      final close = [for (var i = 49; i >= 0; i--) '</t$i>'].join();
      final deep = '$open<x>1</x>$close';
      expect(() => parseSoapArgs(deep), returnsNormally);
      expect(parseSoapArgs(deep).containsKey('x'), isFalse);
    });
  });
}
