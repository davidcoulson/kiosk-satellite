import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/remote/auth.dart';

/// AuthStore token issuing and validation, including the caller-chosen
/// expiry automations use (issue #84).
void main() {
  const secret = 'test-secret';
  late AuthStore auth;

  setUp(() => auth = AuthStore(secret));

  int expOf(String token) {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(token.split('.').first)),
    ) as Map;
    return payload['exp'] as int;
  }

  test('a default token validates and expires in about a week', () {
    final token = auth.issueToken();
    expect(auth.validate(token), isTrue);
    final days = (expOf(token) - DateTime.now().millisecondsSinceEpoch) /
        Duration.millisecondsPerDay;
    expect(days, closeTo(7, 0.01));
  });

  test('a caller-chosen ttl is honored', () {
    final token = auth.issueToken(ttl: const Duration(days: 365));
    expect(auth.validate(token), isTrue);
    final days = (expOf(token) - DateTime.now().millisecondsSinceEpoch) /
        Duration.millisecondsPerDay;
    expect(days, closeTo(365, 0.01));
  });

  test('an absurd ttl is clamped to the ceiling', () {
    final token = auth.issueToken(ttl: const Duration(days: 100000));
    final days = (expOf(token) - DateTime.now().millisecondsSinceEpoch) /
        Duration.millisecondsPerDay;
    expect(days, closeTo(AuthStore.maxTtl.inDays, 0.01));
  });

  test('a zero or negative ttl falls back to the default', () {
    for (final ttl in const [Duration.zero, Duration(days: -5)]) {
      final days = (expOf(auth.issueToken(ttl: ttl)) -
              DateTime.now().millisecondsSinceEpoch) /
          Duration.millisecondsPerDay;
      expect(days, closeTo(7, 0.01));
    }
  });

  test('an expired token is rejected', () {
    // Hand-signed with the same secret, expiry in the past: the signature
    // is valid, only time has run out.
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'exp': DateTime.now()
          .subtract(const Duration(minutes: 1))
          .millisecondsSinceEpoch,
    })));
    final sig = base64Url.encode(
      Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(payload)).bytes,
    );
    expect(auth.validate('$payload.$sig'), isFalse);
  });

  test('tampering breaks a token', () {
    final token = auth.issueToken();
    expect(auth.validate('${token}x'), isFalse);
    expect(auth.validate('not-a-token'), isFalse);
    expect(auth.validate(null), isFalse);
    expect(AuthStore('other-secret').validate(token), isFalse);
  });

  group('tokens name the password they were issued under', () {
    test('a token dies with the password it was issued under', () {
      var version = 'v1';
      final auth = AuthStore('k', passwordVersion: () => version);
      final token = auth.issueToken();
      expect(auth.validate(token), isTrue);
      version = 'v2';
      expect(auth.validate(token), isFalse);
      expect(auth.validate(auth.issueToken()), isTrue);
    });

    test('a token from before the naming lasts until the password changes', () {
      // Issued by a store that names nothing, as every older build did.
      final old = AuthStore('k').issueToken();
      var accepts = true;
      final auth = AuthStore(
        'k',
        passwordVersion: () => 'v1',
        acceptsUnversioned: () => accepts,
      );
      expect(auth.validate(old), isTrue);
      accepts = false;
      expect(auth.validate(old), isFalse);
    });

    test("a fleet token is the leader's and outlives a password change", () {
      var version = 'v1';
      final auth = AuthStore('k', passwordVersion: () => version);
      final fleet = auth.issueToken(claims: {'fleet': 'leader-1'});
      version = 'v2';
      expect(auth.validate(fleet), isTrue);
      expect(auth.claimsOf(fleet)?['pv'], isNull);
    });
  });
}
