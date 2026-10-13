import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/photo_exif.dart';

/// One IFD entry: its tag, TIFF type, count and raw value bytes.
typedef Entry = (int tag, int type, int count, List<int> value);

/// Issue #953: Home Assistant Media and Local Media read the date and the
/// camera from the photo's own EXIF, where Immich's server hands them over.
void main() {
  /// A JPEG whose EXIF holds [ifd0] and, when given, an Exif sub-IFD with
  /// [exif], laid out the way cameras write them: values over four bytes
  /// sit after their IFD and the entries point at them.
  Uint8List jpeg(
    List<Entry> ifd0, {
    List<Entry> exif = const [],
    bool little = true,
  }) {
    final endian = little ? Endian.little : Endian.big;
    List<int> u16(int v) =>
        (ByteData(2)..setUint16(0, v, endian)).buffer.asUint8List();
    List<int> u32(int v) =>
        (ByteData(4)..setUint32(0, v, endian)).buffer.asUint8List();

    final tiff = <int>[
      ...(little ? [0x49, 0x49] : [0x4D, 0x4D]),
      ...u16(42),
      ...u32(8),
    ];
    // Writes an IFD at the current end, its overflow data right after it.
    // Returns the patch position of each entry's value field by tag.
    Map<int, int> writeIfd(List<Entry> entries) {
      final start = tiff.length;
      final dataStart = start + 2 + entries.length * 12 + 4;
      final data = <int>[];
      final fields = <int, int>{};
      tiff.addAll(u16(entries.length));
      for (final (tag, type, count, value) in entries) {
        tiff
          ..addAll(u16(tag))
          ..addAll(u16(type))
          ..addAll(u32(count));
        fields[tag] = tiff.length;
        if (value.length <= 4) {
          tiff.addAll([...value, ...List.filled(4 - value.length, 0)]);
        } else {
          tiff.addAll(u32(dataStart + data.length));
          data.addAll(value);
        }
      }
      tiff
        ..addAll(u32(0))
        ..addAll(data);
      return fields;
    }

    final pointer = exif.isEmpty ? ifd0 : [...ifd0, (0x8769, 4, 1, u32(0))];
    final fields = writeIfd(pointer);
    if (exif.isNotEmpty) {
      final at = fields[0x8769]!;
      tiff.setRange(at, at + 4, u32(tiff.length));
      writeIfd(exif);
    }

    final payload = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff];
    final length = payload.length + 2;
    return Uint8List.fromList([
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // an empty APP0 ahead of it
      0xFF, 0xE1, (length >> 8) & 0xFF, length & 0xFF,
      ...payload,
      0xFF, 0xDA, // start of scan
    ]);
  }

  Entry ascii(int tag, String text) {
    final bytes = [...latin1.encode(text), 0];
    return (tag, 2, bytes.length, bytes);
  }

  Entry rational(
    int tag,
    int numerator,
    int denominator, {
    bool little = true,
  }) {
    final endian = little ? Endian.little : Endian.big;
    final d = ByteData(8)
      ..setUint32(0, numerator, endian)
      ..setUint32(4, denominator, endian);
    return (tag, 5, 1, d.buffer.asUint8List());
  }

  Entry short(int tag, int value, {bool little = true}) {
    final d = ByteData(2)
      ..setUint16(0, value, little ? Endian.little : Endian.big);
    return (tag, 3, 1, d.buffer.asUint8List());
  }

  List<Entry> phone() => [
    ascii(0x010F, 'Google'),
    ascii(0x0110, 'Pixel 8 Pro'),
  ];

  List<Entry> shot({bool little = true}) => [
    ascii(0x9003, '2025:03:29 14:22:05'),
    rational(0x829D, 168, 100, little: little),
    short(0x8827, 50, little: little),
    rational(0x920A, 690, 100, little: little),
  ];

  test('reads the date, camera and exposure, either byte order', () {
    for (final little in [true, false]) {
      final exif = readPhotoExif(
        jpeg(
          phone(),
          exif: shot(little: little),
          little: little,
        ),
      )!;
      expect(exif.taken, DateTime(2025, 3, 29, 14, 22, 5), reason: '$little');
      expect(exif.make, 'Google');
      expect(exif.model, 'Pixel 8 Pro');
      expect(exif.fNumber, closeTo(1.68, 0.001));
      expect(exif.focalLength, closeTo(6.9, 0.001));
      expect(exif.iso, 50);
    }
  });

  test('falls back to the digitized date, never the edit date', () {
    final digitized = readPhotoExif(
      jpeg(phone(), exif: [ascii(0x9004, '2019:07:04 09:00:00')]),
    )!;
    expect(digitized.taken, DateTime(2019, 7, 4, 9));

    // IFD0's DateTime is what an editor rewrites on export.
    final edited = readPhotoExif(
      jpeg([...phone(), ascii(0x0132, '2026:01:01 00:00:00')]),
    )!;
    expect(edited.taken, isNull);
  });

  test('an unset camera clock reads as no date', () {
    for (final blank in ['0000:00:00 00:00:00', '    :  :     :  :  ']) {
      final exif = readPhotoExif(jpeg(phone(), exif: [ascii(0x9003, blank)]));
      expect(exif?.taken, isNull, reason: blank);
    }
  });

  test('anything without EXIF reads as nothing', () {
    expect(readPhotoExif(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isNull);
    expect(readPhotoExif(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDA])), isNull);
    expect(readPhotoExif(Uint8List(0)), isNull);
    expect(readPhotoExif(jpeg([])), isNull);
  });

  test('a head cut short keeps what fits and never throws', () {
    final full = jpeg(phone(), exif: shot());
    for (var cut = 0; cut < full.length; cut++) {
      expect(
        () => readPhotoExif(Uint8List.sublistView(full, 0, cut)),
        returnsNormally,
        reason: 'cut at $cut',
      );
    }
    // The camera strings sit in the first IFD's data, ahead of the Exif
    // sub-IFD, so a cut inside the sub-IFD still names the camera.
    final partial = readPhotoExif(
      Uint8List.sublistView(full, 0, full.length - 40),
    );
    expect(partial?.model, 'Pixel 8 Pro');
  });
}
