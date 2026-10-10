import 'dart:typed_data';

/// [stream] read whole, but never more than [limit] bytes: a response from
/// a host the kiosk does not control (an image a notification or a DLNA
/// sender points at) stops at the cap instead of filling the memory first
/// and being measured afterwards. Throws [StateError] past the cap.
Future<Uint8List> readCapped(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw StateError('larger than ${limit ~/ (1024 * 1024)} MB');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
