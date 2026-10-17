import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';

import 'text_snapshot.dart';

/// Material Design Icons by name, the way Home Assistant names them.
///
/// Home Assistant's own icons are MDI, so anything a user types into an
/// automation or an entity's icon field ("mdi:washing-machine") has to
/// resolve here or the app is guessing at lookalikes. The whole set is
/// bundled as path data under assets/mdi, one file per first letter (see
/// tool/generate_mdi.py); a shard is read when an icon from that letter
/// is first asked for and thrown away again, leaving only the handful of
/// resolved paths a kiosk actually draws.
///
/// Paths rather than an icon font on purpose: the font would be a second
/// megabyte-plus asset AND it would cost the app its icon tree shaking,
/// because looking an icon up by name means a non-const IconData, and
/// that turns the Material font from 25KB into the whole 1.6MB of it.
/// Paths draw through flutter_svg, which is already here for the app's
/// own artwork, and scale to any size (a notification can ask to be drawn
/// four times over).
abstract final class MdiIcons {
  /// Where a shard is read from. Swapped in tests, which cannot wait on
  /// the asset channel from outside a pumping widget test.
  @visibleForTesting
  static Future<String> Function(String assetKey) readShard = (key) =>
      rootBundle.loadString(key, cache: false);

  /// Resolved name to path. Small: only what has actually been drawn.
  static final _resolved = <String, String?>{};

  /// In-flight lookups, so a stack of cards asking for the same icon at
  /// once reads the shard once.
  static final _pending = <String, Future<String?>>{};

  /// Whether [name] looks like an icon name this can resolve. Accepts the
  /// Home Assistant spelling with or without the prefix.
  static bool looksLikeIcon(String name) {
    final trimmed = normalize(name);
    return trimmed.isNotEmpty &&
        RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(trimmed);
  }

  /// The bare icon name: "mdi:washing-machine" and "Washing-Machine" both
  /// become "washing-machine".
  static String normalize(String name) {
    var value = name.trim().toLowerCase();
    if (value.startsWith('mdi:')) value = value.substring(4);
    return value;
  }

  /// The SVG path for [name] on a 24 by 24 grid, or null when no such
  /// icon exists. Cached after the first call.
  static Future<String?> path(String name) {
    final key = normalize(name);
    if (_resolved.containsKey(key)) return Future.value(_resolved[key]);
    // The braces matter: whenComplete waits on whatever its callback
    // returns, and Map.remove hands back the very future being awaited,
    // which is a future waiting on itself.
    return _pending[key] ??= _load(key).whenComplete(() {
      _pending.remove(key);
    });
  }

  /// Every icon name, renamed ones left out, sorted, for the icon picker.
  /// Only the names stay for the session: a few hundred kilobytes less
  /// than the paths.
  static Future<List<String>> names() =>
      _names ??= _readAll().then((all) => all.keys.toList()..sort());
  static Future<List<String>>? _names;

  /// The paths of several icons at once, one shard read per letter rather
  /// than per icon. Names without an icon are left out.
  static Future<Map<String, String>> paths(Iterable<String> names) async {
    final byLetter = <String, List<String>>{};
    final found = <String, String>{};
    for (final name in names.map(normalize).toSet()) {
      final held = _all?[name] ?? _resolved[name];
      if (held != null) {
        found[name] = held;
      } else if (looksLikeIcon(name) && !_resolved.containsKey(name)) {
        byLetter.putIfAbsent(_letter(name), () => []).add(name);
      }
    }
    if (byLetter.isEmpty) return found;
    // The shards decode on a background isolate, which hands back only the
    // asked-for values: a search touches many letters, and decoding them
    // here stalled the kiosk while someone typed in the remote admin.
    final raw = <String, String>{};
    for (final letter in byLetter.keys) {
      try {
        raw[letter] = await readShard('assets/mdi/$letter.json');
      } catch (_) {}
    }
    final values = await Isolate.run(() {
      final out = <String, String?>{};
      for (final MapEntry(key: letter, value: names) in byLetter.entries) {
        final text = raw[letter];
        Map<String, dynamic>? shard;
        try {
          shard = text == null
              ? null
              : jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
        for (final name in names) {
          out[name] = shard?[name] as String?;
        }
      }
      return out;
    });
    for (final MapEntry(key: name, :value) in values.entries) {
      // A renamed icon resolves on its own, under its new name's letter.
      final path = value != null && value.startsWith('@')
          ? await MdiIcons.path(name)
          : _remember(name, value);
      if (path != null) found[name] = path;
    }
    return found;
  }

  /// Icon names containing every word of [query], best matches first: the
  /// name itself, then names starting with it.
  static Future<List<String>> search(String query, {int limit = 60}) async {
    final words = normalize(query).split(RegExp(r'[\s-]+'))
      ..removeWhere((w) => w.isEmpty);
    final all = await names();
    if (words.isEmpty) return all.take(limit).toList();
    final joined = words.join('-');
    int rank(String name) => name == joined
        ? 0
        : name.startsWith(joined)
        ? 1
        : 2;
    final matches = [
      for (final name in all)
        if (words.every(name.contains)) name,
    ]..sort((a, b) => rank(a).compareTo(rank(b)));
    return matches.take(limit).toList();
  }

  /// Keeps every path in memory while an icon picker is open, so scrolling
  /// through thousands of icons never reads a shard per row. [release]
  /// drops them again.
  static Future<void> hold() async {
    _holds++;
    final all = await _readAll();
    if (_holds > 0) _all = all;
  }

  static void release() {
    if (_holds > 0) _holds--;
    if (_holds == 0) _all = null;
  }

  static int _holds = 0;
  static Map<String, String>? _all;

  /// Forgets everything read, for tests that swap [readShard].
  @visibleForTesting
  static void forget() {
    _names = null;
    _all = null;
    _reading = null;
    _holds = 0;
    _resolved.clear();
    _pending.clear();
  }

  /// One scan at a time: the names and a hold opened together share it.
  static Future<Map<String, String>> _readAll() {
    if (_all != null) return Future.value(_all!);
    return _reading ??= _scan().whenComplete(() {
      _reading = null;
    });
  }

  static Future<Map<String, String>>? _reading;

  /// Reads every shard here, where the asset bundle lives, and decodes
  /// them on a background isolate: three megabytes of JSON on the UI
  /// thread stalled even a fast tablet for a beat.
  static Future<Map<String, String>> _scan() async {
    final raw = <String>[];
    for (final letter in [
      for (var c = 0x61; c <= 0x7a; c++) String.fromCharCode(c),
      '_',
    ]) {
      try {
        raw.add(await readShard('assets/mdi/$letter.json'));
      } catch (_) {}
    }
    return Isolate.run(() {
      final all = <String, String>{};
      for (final text in raw) {
        try {
          final shard = jsonDecode(text) as Map<String, dynamic>;
          for (final entry in shard.entries) {
            final value = entry.value;
            if (value is String && !value.startsWith('@')) {
              all[entry.key] = value;
            }
          }
        } catch (_) {}
      }
      return all;
    });
  }

  static String _letter(String key) =>
      key.codeUnitAt(0) >= 0x61 && key.codeUnitAt(0) <= 0x7a ? key[0] : '_';

  static Future<String?> _load(String key, {bool followAlias = true}) async {
    if (!looksLikeIcon(key)) return _remember(key, null);
    final held = _all?[key];
    if (held != null) return held;
    final letter = _letter(key);
    Map<String, dynamic> shard;
    try {
      // The read is uncached because the shard is up to half a megabyte
      // of JSON and this is the only look at it; the resolved paths below
      // are the part worth keeping.
      final raw = await readShard('assets/mdi/$letter.json');
      shard = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return _remember(key, null);
    }
    final value = shard[key] as String?;
    if (value == null) return _remember(key, null);
    // Renamed icons point at their current name rather than carrying a
    // second copy of the path, and the target can be under any letter.
    if (value.startsWith('@')) {
      if (!followAlias) return _remember(key, null);
      final target = await _load(value.substring(1), followAlias: false);
      return _remember(key, target);
    }
    return _remember(key, value);
  }

  static String? _remember(String key, String? path) {
    _resolved[key] = path;
    return path;
  }
}

/// Draws a Material Design Icon by name, falling back to [fallback] while
/// the path is being read and when the name is not an icon at all.
class MdiIcon extends StatefulWidget {
  const MdiIcon({
    required this.name,
    required this.size,
    required this.color,
    required this.fallback,
    this.shadows = const [],
    super.key,
  });

  final String name;
  final double size;
  final Color color;

  /// Drawn as blurred copies under the glyph, since an SVG has no shadow of
  /// its own.
  final List<Shadow> shadows;

  /// What to draw instead: an unknown name must still leave something in
  /// the circle, and the kind icon is the honest answer.
  final IconData fallback;

  @override
  State<MdiIcon> createState() => _MdiIconState();
}

class _MdiIconState extends State<MdiIcon> {
  String? _path;
  bool _looked = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(MdiIcon old) {
    super.didUpdateWidget(old);
    if (old.name != widget.name) {
      _looked = false;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final name = widget.name;
    final path = await MdiIcons.path(name);
    // The SVG is compiled on a background isolate the first time, and
    // until then the glyph draws as nothing. Waiting for it here keeps
    // the fallback up meanwhile and lets the glyph paint within a frame
    // of replacing it.
    if (path != null) {
      try {
        await SvgStringLoader(_svg(path)).loadBytes(null);
      } catch (_) {}
    }
    if (!mounted || widget.name != name) return;
    setState(() {
      _path = path;
      _looked = true;
    });
    // A snapshot around the icon (the shadowed At a Glance chips) would
    // otherwise keep the fallback it captured, since a child repainting
    // does not retake it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) TextSnapshot.refresh(context);
    });
  }

  static String _svg(String path) =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
      '<path d="$path"/></svg>';

  @override
  Widget build(BuildContext context) {
    final path = _path;
    if (!_looked || path == null) {
      return Icon(
        widget.fallback,
        size: widget.size,
        color: widget.color,
        shadows: widget.shadows,
      );
    }
    Widget glyph(Color color) => SvgPicture.string(
      _svg(path),
      width: widget.size,
      height: widget.size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
    if (widget.shadows.isEmpty) return glyph(widget.color);
    return Stack(
      children: [
        for (final shadow in widget.shadows)
          Transform.translate(
            offset: shadow.offset,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: shadow.blurSigma,
                sigmaY: shadow.blurSigma,
              ),
              child: glyph(shadow.color),
            ),
          ),
        glyph(widget.color),
      ],
    );
  }
}
