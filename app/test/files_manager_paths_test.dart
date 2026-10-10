import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/files/files_manager.dart';

void main() {
  late Directory root;
  late Directory outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ks-root-');
    outside = Directory.systemTemp.createTempSync('ks-outside-');
    File('${outside.path}/secret.txt').writeAsStringSync('x');
    Directory('${root.path}/music').createSync();
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    outside.deleteSync(recursive: true);
  });

  test('a path inside the root, existing or not yet, stays inside', () {
    expect(FilesManager.staysInside(root.path, '${root.path}/music'), isTrue);
    expect(
      FilesManager.staysInside(root.path, '${root.path}/music/new.mp3'),
      isTrue,
    );
  });

  test('a symbolic link under the root that points out of it does not', () {
    Link('${root.path}/escape').createSync(outside.path);
    expect(
      FilesManager.staysInside(root.path, '${root.path}/escape/secret.txt'),
      isFalse,
    );
    // An upload through the link is refused as well.
    expect(
      FilesManager.staysInside(root.path, '${root.path}/escape/new.txt'),
      isFalse,
    );
  });
}
