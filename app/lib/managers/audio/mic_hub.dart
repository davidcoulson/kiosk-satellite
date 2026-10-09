import 'dart:async';

import 'package:flutter/foundation.dart';

import '../wake_word/vsww/native_mic.dart';

/// One native microphone capture shared by wake detection, claps and RTSP.
/// Capture opens for the first subscriber and closes after the last leaves.
class MicHub {
  MicHub._();

  static final MicHub instance = MicHub._();

  /// Opens the underlying native capture. Replaced in tests.
  Stream<Uint8List> Function() opener = () => NativeMic().stream();
  final browserCapturing = ValueNotifier<bool>(false);
  StreamController<Uint8List>? _out;
  final _tap = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _native;
  Future<void> _pending = Future.value();

  bool get capturing => _native != null;

  Stream<Uint8List> stream() {
    _out ??= StreamController<Uint8List>.broadcast(
      onListen: () => unawaited(_sync()),
      onCancel: () => unawaited(_sync()),
    );
    return _out!.stream;
  }

  /// The chunks of a capture someone else holds open. Listening here never
  /// opens the microphone, so a reader of the room's noise level records
  /// nothing the wake word engine was not already hearing.
  Stream<Uint8List> tap() => _tap.stream;

  Future<void> _sync({bool reopen = false}) {
    _pending = _pending
        .then((_) async {
          final wanted = _out?.hasListener == true && !browserCapturing.value;
          if (!wanted || reopen) {
            final sub = _native;
            _native = null;
            await sub?.cancel();
          }
          if (wanted && _native == null) {
            _native = opener().listen((chunk) {
              _out?.add(chunk);
              if (_tap.hasListener) _tap.add(chunk);
            }, onError: (Object e) => _out?.addError(e));
          }
        })
        .catchError((Object e) {
          _out?.addError(e);
        });
    return _pending;
  }

  /// Browser capture gets exclusive ownership until its last track stops.
  /// Wait for native cancellation before allowing getUserMedia to proceed.
  Future<void> setBrowserCapturing(bool active) {
    browserCapturing.value = active;
    return _sync();
  }

  /// Apply changed device, source, gain, AGC or channel settings.
  Future<void> bounce() => _sync(reopen: true);
}
