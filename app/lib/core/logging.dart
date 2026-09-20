import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

class LogEntry {
  LogEntry(this.time, this.level, this.tag, this.message, {this.repeats = 1});

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  /// How many times this line was logged, when identical lines arrived close
  /// enough together to be collapsed into one (see [Logger]).
  final int repeats;

  Map<String, Object?> toJson() => {
    'time': time.toIso8601String(),
    'level': level.name,
    'tag': tag,
    'message': repeats > 1 ? '$message (x$repeats)' : message,
    if (repeats > 1) 'repeats': repeats,
  };
}

/// Ring-buffer logger. The remote UI tails [stream] over its WebSocket and
/// fetches [recent] on connect.
///
/// Identical debug and info lines arriving within [_repeatWindow] are
/// collapsed into one carrying a count, because the ring is a diagnostic record and polling was
/// erasing it: ESPHome reads its sensors and every plugin polls its dashboard
/// state on a timer, which on a working panel filled all 500 entries with the
/// same handful of lines every fifteen minutes. Anything worth reading later
/// -- a wake word firing at 2am, a camera giving up -- was gone by morning.
/// A collapsed line is still one line, so a poll that stops, starts or
/// changes its message still shows up.
class Logger {
  static const _capacity = 4000;

  /// Long enough to swallow a poll cycle, short enough that the log still
  /// reads as a timeline rather than a tally.
  static const _repeatWindow = Duration(minutes: 2);

  final _buffer = ListQueue<LogEntry>(_capacity);
  final _controller = StreamController<LogEntry>.broadcast();
  final _pending = <String, _Repeat>{};

  Stream<LogEntry> get stream => _controller.stream;
  List<LogEntry> get recent => _buffer.toList(growable: false);

  void debug(String tag, String message) => _add(LogLevel.debug, tag, message);
  void info(String tag, String message) => _add(LogLevel.info, tag, message);
  void warn(String tag, String message) => _add(LogLevel.warn, tag, message);
  void error(String tag, String message) => _add(LogLevel.error, tag, message);

  void _add(LogLevel level, String tag, String message) {
    final now = DateTime.now();
    // Only the chatty levels collapse. A warning or an error repeating is
    // itself the finding -- a renderer retrying every thirty seconds, a
    // socket refusing every poll -- and counting those as one line would
    // hide exactly the shape someone reading the log is looking for.
    if (level == LogLevel.warn || level == LogLevel.error) {
      _flushExpired(now);
      _emit(LogEntry(now, level, tag, message));
      return;
    }
    final key = '${level.index}\u0000$tag\u0000$message';
    _flushExpired(now, except: key);
    final open = _pending[key];
    if (open != null && now.difference(open.last) < _repeatWindow) {
      // Already counted; it is emitted once the run ends.
      open.count++;
      open.last = now;
      return;
    }
    _pending[key] = _Repeat(now);
    _emit(LogEntry(now, level, tag, message));
  }

  /// Emits the tally for any run of repeats that has gone quiet, so a burst
  /// that stops is still counted rather than waiting on a line that never
  /// comes again.
  void _flushExpired(DateTime now, {String? except}) {
    if (_pending.isEmpty) return;
    final done = <String>[];
    for (final entry in _pending.entries) {
      if (entry.key == except) continue;
      if (now.difference(entry.value.last) < _repeatWindow) continue;
      done.add(entry.key);
    }
    for (final key in done) {
      final run = _pending.remove(key)!;
      if (run.count <= 1) continue;
      final parts = key.split('\u0000');
      _emit(
        LogEntry(
          run.last,
          LogLevel.values[int.parse(parts[0])],
          parts[1],
          parts[2],
          repeats: run.count,
        ),
      );
    }
  }

  void _emit(LogEntry entry) {
    if (_buffer.length >= _capacity) _buffer.removeFirst();
    _buffer.addLast(entry);
    if (!_controller.isClosed) _controller.add(entry);
    final level = entry.level;
    final tag = entry.tag;
    final message = entry.message;
    // Warnings and errors also go to the platform log, in release too: when
    // something breaks the remote admin itself, this ring buffer is only
    // readable through the very server that is down, and `adb logcat` is all
    // that is left. Debug and info stay out of it — they are the noisy ones,
    // and the remote UI tails them live.
    if (kDebugMode || level == LogLevel.warn || level == LogLevel.error) {
      debugPrint('[${level.name}] $tag: $message');
    }
  }

  Future<void> dispose() => _controller.close();
}

/// A run of identical lines: when it started counting and how many since.
class _Repeat {
  _Repeat(this.last);

  DateTime last;
  int count = 1;
}
