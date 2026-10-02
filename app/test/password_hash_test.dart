import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/remote/password_hash.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The stored form of the remote admin password. The derivation is checked
/// against published PBKDF2-HMAC-SHA256 vectors rather than against itself:
/// a hand-written KDF that agrees with its own output proves nothing.
void main() {
  test('derives the published PBKDF2-HMAC-SHA256 vectors', () {
    final p = utf8.encode('password');
    final s = utf8.encode('salt');
    expect(
      _hex(PasswordHash.derive(p, s, 1)),
      '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    );
    expect(
      _hex(PasswordHash.derive(p, s, 2)),
      'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
    );
    expect(
      _hex(PasswordHash.derive(p, s, 4096)),
      'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
    );
  });

  test('checks a password without keeping it', () {
    final stored = PasswordHash.hash('correct horse');
    expect(PasswordHash.isHashed(stored), isTrue);
    expect(stored, isNot(contains('correct horse')));
    expect(PasswordHash.verify(stored, 'correct horse'), isTrue);
    expect(PasswordHash.verify(stored, 'correct horsf'), isFalse);
    expect(PasswordHash.verify(stored, ''), isFalse);
    // What is stored is not itself a way in.
    expect(PasswordHash.verify(stored, stored), isFalse);
  });

  test('the same password never stores the same way twice', () {
    expect(PasswordHash.hash('same'), isNot(PasswordHash.hash('same')));
  });

  test('a password kept as typed by an older build still checks', () {
    expect(PasswordHash.verify('legacy', 'legacy'), isTrue);
    expect(PasswordHash.verify('legacy', 'legacx'), isFalse);
    expect(PasswordHash.verify('', ''), isFalse);
  });

  test('a damaged stored value refuses instead of throwing', () {
    for (final bad in [
      r'pbkdf2-sha256$',
      r'pbkdf2-sha256$abc$AA==$AA==',
      r'pbkdf2-sha256$0$AA==$AA==',
      r'pbkdf2-sha256$99999999$AA==$AA==',
      r'pbkdf2-sha256$10$***$AA==',
    ]) {
      expect(PasswordHash.verify(bad, 'anything'), isFalse, reason: bad);
    }
  });

  test('the version follows the stored value', () {
    final a = PasswordHash.hash('one');
    expect(PasswordHash.versionOf(a), PasswordHash.versionOf(a));
    expect(
      PasswordHash.versionOf(a),
      isNot(PasswordHash.versionOf(PasswordHash.hash('one'))),
    );
  });

  test('the isolate form agrees with the direct one', () async {
    final stored = PasswordHash.hash('off-thread');
    expect(await PasswordHash.verifyAsync(stored, 'off-thread'), isTrue);
    expect(await PasswordHash.verifyAsync(stored, 'nope'), isFalse);
  });
}
