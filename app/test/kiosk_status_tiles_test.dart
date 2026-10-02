import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/ui/kiosk_status_tiles.dart';

/// The on-device tiles read the same commands as Remote Admin's Overview,
/// so the wording and severity here are checked against what overview.js
/// paints for the same payload. A panel and its admin page disagreeing
/// about the panel's own state would be worse than showing nothing.
void main() {
  group('Home Assistant', () {
    test('a missing answer is unavailable, not a failure', () {
      expect(haTile(null).text, 'Status unavailable');
      expect(haTile(null).level, '');
    });
    test('unconfigured asks for setup', () {
      final tile = haTile({'configured': false, 'connected': false});
      expect(tile.text, 'Not set up');
      expect(tile.level, 'warn');
    });
    // Remote Admin says "Connected" here, but the flag behind it is a
    // latch: proven once this run, never cleared when HA goes away. The
    // panel says what it can actually stand behind.
    test('a passed check reads as validated, not connected', () {
      final tile = haTile({'configured': true, 'connected': true});
      expect(tile.text, 'Validated');
      expect(tile.level, 'on');
    });
    test('a failed check is an error state', () {
      expect(haTile({'configured': true, 'connected': false}).level, 'off');
    });
  });

  group('Voice Satellite', () {
    test('the feature being off is neutral, not a warning', () {
      final tile = voiceTile(null, false);
      expect(tile.text, 'Wake word detection off');
      expect(tile.level, '');
    });
    test('listening names the wake words', () {
      final tile = voiceTile({
        'listening': true,
        'models': [
          {'wakeWord': 'Alexa'},
          {'wakeWord': 'Jarvis'},
        ],
      }, true);
      expect(tile.text, 'Listening for Alexa, Jarvis');
      expect(tile.level, 'on');
    });
    test('listening without usable model names still reads as listening', () {
      final tile = voiceTile({'listening': true, 'models': []}, true);
      expect(tile.text, 'Listening');
    });
    test('released carries the reason it stopped', () {
      final tile = voiceTile(
          {'released': true, 'releaseReason': 'Microphone in use'}, true);
      expect(tile.text, 'Microphone in use');
      expect(tile.level, 'warn');
    });
  });

  group('ESPHome', () {
    test('not running is off', () {
      expect(esphomeTile({'running': false}, true, false).text, 'Off');
    });
    // A server subscribed to entities counts as connected even with no
    // proxy signals: the proxy signals alone used to decide, so an
    // entities-only server read as waiting while it served everything.
    test('an entities-only client counts as connected', () {
      final tile = esphomeTile({'running': true, 'clients': 1}, true, false);
      expect(tile.text, 'Entities only');
      expect(tile.level, 'on');
    });
    test('both switches on says so', () {
      final tile = esphomeTile({'running': true, 'subscribers': 2}, true, true);
      expect(tile.text, 'Entities and BT proxy');
    });
    test('running with nothing attached is waiting', () {
      final tile = esphomeTile({'running': true, 'clients': 0}, true, true);
      expect(tile.text, 'Waiting for Home Assistant');
      expect(tile.level, 'warn');
    });
  });

  group('Media Player', () {
    // Idle is a player's normal state, not a fault: nothing here should
    // ask someone to go and fix a quiet speaker.
    test('idle is neutral and names where', () {
      final tile = mediaTile({
        'enabled': true,
        'playing': false,
        'serverName': 'Music Assistant (d5369777-music-assistant)',
      });
      expect(tile.text, 'Idle - Music Assistant');
      expect(tile.level, '');
    });
    test('only playing is green', () {
      final tile = mediaTile(
          {'enabled': true, 'playing': true, 'remotePlayer': 'Kitchen'});
      expect(tile.text, 'Playing - Kitchen');
      expect(tile.level, 'on');
    });
    test('paused is neutral', () {
      final tile =
          mediaTile({'enabled': true, 'playbackState': 'paused'});
      expect(tile.text, 'Paused');
      expect(tile.level, '');
    });
  });

  group('Service', () {
    test('running counts its features', () {
      final tile = serviceTile({
        'running': true,
        'reasons': ['a', 'b', 'c', 'd'],
      });
      expect(tile.text, 'Running - 4 features');
      expect(tile.level, 'on');
    });
    test('one feature is singular', () {
      final tile = serviceTile({'running': true, 'reasons': ['a']});
      expect(tile.text, 'Running - 1 feature');
    });
    test('an error outranks not running', () {
      final tile = serviceTile({'running': false, 'error': 'Crashed'});
      expect(tile.text, 'Crashed');
      expect(tile.level, 'off');
    });
  });

  group('App Version', () {
    test('up to date names the running version', () {
      final tile = updateTile({'currentVersion': '2026.9.45'});
      expect(tile.text, 'Up to date: 2026.9.45');
      expect(tile.level, 'on');
    });
    test('an available version is worth attention', () {
      final tile = updateTile(
          {'currentVersion': '2026.9.45', 'availableVersion': '2026.9.46'});
      expect(tile.text, 'New version: 2026.9.46');
      expect(tile.level, 'warn');
    });
    test('a download in progress outranks the availability notice', () {
      final tile = updateTile({'availableVersion': '2026.9.46', 'progress': 0.4});
      expect(tile.text, 'Downloading: 2026.9.46');
      expect(tile.level, 'warn');
    });
  });
}
