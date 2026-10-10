import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/remote/password_hash.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;

void main() {
  // A login accepts at most maxAdminPasswordLength characters, so a longer
  // password, once set, could never be typed back in.
  test('a typed admin password longer than a login accepts is refused', () {
    final check = defs.remotePassword.validator!;
    expect(check('x' * defs.maxAdminPasswordLength), isNull);
    expect(check('x' * (defs.maxAdminPasswordLength + 1)), isNotNull);
  });

  test('a stored hash being restored is not a typed password', () {
    final check = defs.remotePassword.validator!;
    expect(check(PasswordHash.hash('x' * 4000)), isNull);
  });
}
