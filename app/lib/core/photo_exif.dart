/// The capture details a JPEG carries in its EXIF block: when it was taken,
/// the camera and the exposure. Read for the screensaver metadata panel on
/// sources that hand over the file itself (Local Media, and Home Assistant
/// Media through its signed URL), where no server has parsed them for us
/// the way Immich does.
///
/// Only the head of the file is needed. The EXIF segment sits ahead of the
/// image data and is at most 64 KB, so a caller can pass the first chunk of
/// a large photo and a segment cut short simply yields fewer fields.
library;

import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

/// How much of a file holds its EXIF block, generously: the segment's own
/// limit plus room for the JFIF and XMP segments that can come first.
const photoExifHeadBytes = 192 * 1024;

class PhotoExif {
  const PhotoExif({
    this.taken,
    this.make,
    this.model,
    this.focalLength,
    this.fNumber,
    this.iso,
  });

  /// The moment the shutter fired, in the camera's own clock. EXIF stores
  /// no zone with it, so it is kept as a local wall time.
  final DateTime? taken;
  final String? make;
  final String? model;
  final double? focalLength;
  final double? fNumber;
  final int? iso;

  bool get isEmpty =>
      taken == null &&
      make == null &&
      model == null &&
      focalLength == null &&
      fNumber == null &&
      iso == null;
}

/// The EXIF details of a JPEG, or null for anything that is not a JPEG or
/// carries no readable EXIF. Malformed or truncated input never throws.
PhotoExif? readPhotoExif(Uint8List bytes) {
  try {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
    final data = ByteData.sublistView(bytes);
    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xFF) return null; // out of step with the markers
      final marker = bytes[offset + 1];
      // Standalone markers carry no length. Start of scan means the
      // metadata is behind us.
      if (marker == 0xD8 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        offset += 2;
        continue;
      }
      if (marker == 0xDA || marker == 0xD9) return null;
      final length = data.getUint16(offset + 2);
      if (length < 2) return null;
      final segment = offset + 4;
      final end = segment + length - 2;
      if (marker == 0xE1 &&
          bytes.length - segment > 6 &&
          bytes[segment] == 0x45 && // E
          bytes[segment + 1] == 0x78 && // x
          bytes[segment + 2] == 0x69 && // i
          bytes[segment + 3] == 0x66 && // f
          bytes[segment + 4] == 0x00) {
        // A segment cut off by the caller's head limit still yields what
        // fits: every read below checks its own bounds.
        final exif = _Tiff.read(data, segment + 6, min(end, bytes.length));
        return exif == null || exif.isEmpty ? null : exif;
      }
      offset = end;
    }
  } catch (_) {
    // Decoration only: a photo whose header cannot be read shows no
    // details rather than failing the slide.
  }
  return null;
}

/// One TIFF block: the byte order, its bounds and the tags this file reads.
class _Tiff {
  _Tiff(this.data, this.start, this.end, this.endian);

  final ByteData data;
  final int start;
  final int end;
  final Endian endian;

  static const _make = 0x010F;
  static const _model = 0x0110;
  static const _exifPointer = 0x8769;
  static const _fNumber = 0x829D;
  static const _iso = 0x8827;
  static const _dateTimeOriginal = 0x9003;
  static const _dateTimeDigitized = 0x9004;
  static const _focalLength = 0x920A;

  static PhotoExif? read(ByteData data, int start, int end) {
    if (start + 8 > end) return null;
    final order = data.getUint16(start);
    if (order != 0x4949 && order != 0x4D4D) return null;
    final endian = order == 0x4949 ? Endian.little : Endian.big;
    if (data.getUint16(start + 2, endian) != 42) return null;
    final tiff = _Tiff(data, start, end, endian);
    final ifd0 = tiff._entries(data.getUint32(start + 4, endian));
    final exifOffset = ifd0[_exifPointer];
    final exif = exifOffset == null
        ? const <int, int>{}
        : tiff._entries(tiff._long(exifOffset) ?? -1);
    return PhotoExif(
      // Original first. Digitized is the same moment for a camera and the
      // scan for a film photo. IFD0's DateTime is left out on purpose: an
      // editor rewrites it, so it dates the export, not the photo.
      taken:
          tiff._date(exif[_dateTimeOriginal]) ??
          tiff._date(exif[_dateTimeDigitized]),
      make: tiff._ascii(ifd0[_make]),
      model: tiff._ascii(ifd0[_model]),
      focalLength: tiff._rational(exif[_focalLength]),
      fNumber: tiff._rational(exif[_fNumber]),
      iso: tiff._short(exif[_iso]),
    );
  }

  /// The IFD at [offset] (relative to the TIFF header) as tag to entry
  /// position. Entries past the readable end are dropped.
  Map<int, int> _entries(int offset) {
    final ifd = start + offset;
    if (offset < 0 || ifd + 2 > end) return const {};
    final count = data.getUint16(ifd, endian);
    return {
      for (var i = 0; i < count; i++)
        if (ifd + 2 + i * 12 + 12 <= end)
          data.getUint16(ifd + 2 + i * 12, endian): ifd + 2 + i * 12,
    };
  }

  int _type(int entry) => data.getUint16(entry + 2, endian);
  int _count(int entry) => data.getUint32(entry + 4, endian);

  /// Where an entry's value lives: in the entry itself when it fits in four
  /// bytes, else at the offset the entry holds. Null when out of bounds.
  int? _value(int entry, int size) {
    final at = size <= 4
        ? entry + 8
        : start + data.getUint32(entry + 8, endian);
    return at + size <= end ? at : null;
  }

  int? _long(int? entry) {
    if (entry == null || _type(entry) != 4) return null;
    final at = _value(entry, 4);
    return at == null ? null : data.getUint32(at, endian);
  }

  int? _short(int? entry) {
    if (entry == null || _count(entry) < 1) return null;
    return switch (_type(entry)) {
      3 => data.getUint16(entry + 8, endian),
      4 => _long(entry),
      _ => null,
    };
  }

  double? _rational(int? entry) {
    if (entry == null || _type(entry) != 5 || _count(entry) < 1) return null;
    final at = _value(entry, 8);
    if (at == null) return null;
    final numerator = data.getUint32(at, endian);
    final denominator = data.getUint32(at + 4, endian);
    if (denominator == 0 || numerator == 0) return null;
    return numerator / denominator;
  }

  String? _ascii(int? entry) {
    if (entry == null || _type(entry) != 2) return null;
    final count = _count(entry);
    if (count == 0 || count > 256) return null;
    final at = _value(entry, count);
    if (at == null) return null;
    final raw = data.buffer.asUint8List(data.offsetInBytes + at, count);
    final nul = raw.indexOf(0);
    final text = latin1
        .decode(nul < 0 ? raw : raw.sublist(0, nul), allowInvalid: true)
        .trim();
    return text.isEmpty ? null : text;
  }

  /// "YYYY:MM:DD HH:MM:SS". Cameras with an unset clock write zeros or
  /// spaces, which read as no date rather than the year zero.
  DateTime? _date(int? entry) {
    final text = _ascii(entry);
    if (text == null) return null;
    final m = RegExp(
      r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(text);
    if (m == null) return null;
    final parts = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    if (parts[0] < 1800 || parts[1] < 1 || parts[1] > 12) return null;
    if (parts[2] < 1 || parts[2] > 31) return null;
    return DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
  }
}
