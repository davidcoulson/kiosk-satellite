import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;

/// The remote admin password as it is kept: salted and stretched, never as
/// typed.
///
/// It used to sit in the preferences file as typed, where anything able to
/// read that file -- a backup, ADB on a rooted panel -- read the password
/// itself, and a password is the one secret on the device likely to be in use
/// somewhere else too. What is stored now lets the app check a password and
/// tells a reader nothing they can type.
///
/// PBKDF2-HMAC-SHA256, written out because the app ships no native crypto
/// binding and this runs a handful of times a day. It costs over a tenth of
/// a second on a desktop and several times that on the slowest panels, so
/// the login path, which anyone on the network can drive, checks on another
/// isolate ([verifyAsync]) rather than stall a screensaver mid-fade. Setting
/// one happens about once in a panel's life and is done in place. Login is already
/// throttled to five tries in five minutes per address; the stretching is
/// there to make an offline search of a stolen file expensive.
abstract final class PasswordHash {
  static const _scheme = 'pbkdf2-sha256';
  static const _iterations = 12000;

  /// Whether [stored] is already in the kept form.
  static bool isHashed(String stored) => stored.startsWith('$_scheme\$');

  /// [password] in the kept form, under a fresh salt.
  static String hash(String password) {
    final source = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => source.nextInt(256)),
    );
    final derived = _pbkdf2(utf8.encode(password), salt, _iterations);
    return '$_scheme\$$_iterations\$${base64Url.encode(salt)}'
        '\$${base64Url.encode(derived)}';
  }

  /// Whether [password] is the one [stored] was made from. A value that is
  /// not in the kept form is compared as typed, which is what makes the
  /// first login after an upgrade work before the migration has run.
  static bool verify(String stored, String password) {
    if (stored.isEmpty || password.isEmpty) return false;
    if (!isHashed(stored)) {
      return _equal(utf8.encode(stored), utf8.encode(password));
    }
    final parts = stored.split(r'$');
    if (parts.length != 4) return false;
    final iterations = int.tryParse(parts[1]);
    if (iterations == null || iterations < 1 || iterations > 1000000) {
      return false;
    }
    try {
      final salt = base64Url.decode(parts[2]);
      final expected = base64Url.decode(parts[3]);
      return _equal(_pbkdf2(utf8.encode(password), salt, iterations), expected);
    } on FormatException {
      return false;
    }
  }

  /// [verify] on another isolate.
  static Future<bool> verifyAsync(String stored, String password) =>
      compute(_verifyPair, (stored, password));

  static bool _verifyPair((String, String) pair) => verify(pair.$1, pair.$2);

  @visibleForTesting
  static Uint8List derive(List<int> password, List<int> salt, int iterations) =>
      _pbkdf2(password, salt, iterations);

  /// A short name for [stored] that changes whenever the password does,
  /// carried in session tokens so a password change retires them.
  static String versionOf(String stored) => sha256
      .convert(utf8.encode('ks-password-version\n$stored'))
      .toString()
      .substring(0, 16);

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// One 32-byte block, which is all a SHA-256 PBKDF2 needs for a 256-bit key.
  static Uint8List _pbkdf2(List<int> password, List<int> salt, int iterations) {
    final mac = Hmac(sha256, password);
    var u = mac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = mac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }
}
