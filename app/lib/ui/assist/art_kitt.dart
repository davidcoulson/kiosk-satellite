import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'assist_art.dart';

/// The KITT skin's indicator: the voice box from Knight Rider's dash. Three
/// columns of red blocks light outward from their middle with the voice,
/// the outer two always a block shorter than the centre, brightest at the
/// middle and fading toward the tips. At rest only the middle of each
/// column glows. While the assistant thinks the columns swell and ease.
/// One block and its glow are an image drawn once, and every lit block is
/// a tinted copy of it in a single atlas draw, so a frame costs one draw
/// and no blur.
class KittArt extends StatefulWidget {
  const KittArt({
    super.key,
    required this.mode,
    required this.reactive,
    required this.level,
    required this.clock,
    this.compact = false,
    this.countdown,
    this.box,
  });

  final ArtMode mode;

  /// Listening or speaking with the reactive bar on: the columns follow
  /// [level]. Otherwise they run the mode's own animation.
  final bool reactive;
  final ValueListenable<double> level;
  final ArtClock clock;

  /// Docked over the dashboard: the voice box sits on a dark plate that
  /// fills its box.
  final bool compact;

  /// 1 down to 0 as a docked conversation ends: a bar under the columns
  /// shrinks toward the middle with it.
  final ValueListenable<double>? countdown;

  /// Where the voice box goes, in the widget's own coordinates. Null fills
  /// the widget.
  final Rect? box;

  @override
  State<KittArt> createState() => _KittArtState();
}

class _KittArtState extends State<KittArt> {
  /// How far the centre column lights from its middle (0 to 1) as drawn,
  /// eased toward its target every frame so a change of mode glides.
  double _reach = 0;

  /// 1 at rest, 0 while active, eased the same way.
  double _rest = 1;
  double _last = -1;

  /// The loudest recent level while listening and while speaking, each
  /// decaying, as the Voice Only mark scales them.
  double _micPeak = 0;
  double _playPeak = 0;

  /// One block with its glow, drawn at [_spritePx] pixels per artboard
  /// unit.
  ui.Image? _sprite;
  double _spritePx = 0;

  /// Reused every frame by the atlas draw: one entry per block.
  final _transforms = Float32List(_KittPainter.blocks * 4);
  final _rects = Float32List(_KittPainter.blocks * 4);
  final _tints = Int32List(_KittPainter.blocks);

  /// The sprite at about [px] pixels per artboard unit. A small change of
  /// size keeps the one already drawn.
  ui.Image sprite(double px) {
    final current = _sprite;
    if (current != null && px <= _spritePx * 1.15 && px >= _spritePx / 1.5) {
      return current;
    }
    current?.dispose();
    _spritePx = px;
    final image = _KittPainter.bake(px);
    _sprite = image;
    for (var i = 0; i < _KittPainter.blocks; i++) {
      _rects
        ..[i * 4] = 0
        ..[i * 4 + 1] = 0
        ..[i * 4 + 2] = image.width.toDouble()
        ..[i * 4 + 3] = image.height.toDouble();
    }
    return image;
  }

  @override
  void dispose() {
    _sprite?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.infinite,
      painter: _KittPainter(this, MediaQuery.devicePixelRatioOf(context)),
    ),
  );
}

class _KittPainter extends CustomPainter {
  _KittPainter(this.state, this.pixelRatio)
    : super(
        repaint: Listenable.merge([
          state.widget.level,
          state.widget.clock,
          state.widget.countdown,
        ]),
      );

  final _KittArtState state;
  final double pixelRatio;
  KittArt get w => state.widget;

  /// Segments in each column: the centre one is the longest.
  static const _rows = [19, 21, 19];
  static const blocks = 19 + 21 + 19;
  static const _red = Color(0xFFFF0A00);

  /// The artboard, in design units: three columns of blocks, the centre
  /// one reaching furthest.
  static const _columnWidth = 90.0, _columnGap = 67.0;
  static const _segment = 34.0, _pitch = 41.0;
  static const _artW = _columnWidth * 3 + _columnGap * 2;
  static const _artH = 21 * _pitch - (_pitch - _segment);

  /// The glow around a block: how far it spreads and its blur.
  static const _halo = _segment * 0.15, _sigma = 9.0;

  /// The sprite's margin past the block on every side, room for the glow.
  static const _margin = _halo + 3 * _sigma;

  /// Docked: the plate's padding around the columns, and the countdown
  /// bar under them.
  static const _pad = 44.0, _barGap = 30.0, _barHeight = 10.0;
  static const _plateW = _artW + 2 * _pad;
  static const _plateH = _artH + _barGap + _barHeight + 2 * _pad;

  static final _atlas = Paint()..filterQuality = FilterQuality.low;

  /// One lit block at [px] pixels per artboard unit: a shade darker at its
  /// top than its bottom, with its soft red glow around it.
  static ui.Image bake(double px) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final block = Rect.fromLTWH(
      _margin * px,
      _margin * px,
      _columnWidth * px,
      _segment * px,
    );
    final radius = Radius.circular(_segment * 0.06 * px);
    // The blur is set in pixels, unscaled, so both renderers agree on it.
    canvas.drawRRect(
      RRect.fromRectAndRadius(block.inflate(_halo * px), radius),
      Paint()
        ..color = _red.withValues(alpha: 0.28)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, _sigma * px),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(block, radius),
      Paint()
        ..shader = ui.Gradient.linear(block.topCenter, block.bottomCenter, [
          Color.lerp(Colors.black, _red, 0.82)!,
          _red,
        ]),
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      ((_columnWidth + 2 * _margin) * px).ceil(),
      ((_segment + 2 * _margin) * px).ceil(),
    );
    picture.dispose();
    return image;
  }

  /// A steady pseudo-random 0 to 1 for one tick, so the bars jump from
  /// beat to beat like the dash's, rather than gliding.
  static double _jitter(int tick) {
    final x = math.sin(tick * 12.9898 + 78.233) * 43758.5453;
    return x - x.floorToDouble();
  }

  /// The level against its source's recent peak: a peak decays to half in
  /// about two seconds, and the gain stops at 4x so room noise stays low.
  double _scaled(double dt) {
    final l = w.level.value.clamp(0.0, 1.0);
    final decay = math.exp(-0.35 * dt);
    final speaking = w.mode == ArtMode.speaking;
    final peak = math.max(
      l,
      (speaking ? state._playPeak : state._micPeak) * decay,
    );
    if (speaking) {
      state._playPeak = peak;
    } else {
      state._micPeak = peak;
    }
    return (l * math.min(4.0, 0.9 / math.max(peak, 0.1))).clamp(0.0, 1.0);
  }

  /// 0 to 1: how far from the middle row the centre column lights.
  double _target(double t, double l) {
    switch (w.mode) {
      case ArtMode.idle:
        return 0;
      case ArtMode.thinking:
        return 0.12 + 0.3 * (0.5 + 0.5 * math.sin(t * 3.2));
      case ArtMode.speaking when w.reactive:
        return l * (0.45 + 0.55 * _jitter((t * 16).floor()));
      case ArtMode.listening when w.reactive:
        return l * 0.8 * (0.5 + 0.5 * _jitter((t * 12).floor()));
      case ArtMode.speaking:
        // No level to follow: the dash's own chatter.
        return 0.2 + 0.55 * _jitter((t * 8).floor());
      case ArtMode.listening:
        return 0.06 + 0.04 * math.sin(2 * math.pi * t / 2.4);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final watch = Stopwatch()..start();
    final t = w.clock.seconds;
    final dt = state._last < 0 ? 1.0 : (t - state._last).clamp(0.0, 0.1);
    state._last = t;
    final l = w.reactive ? _scaled(dt) : 0.0;
    // About 25 ms to most of a step: the beats still read as jumps, and a
    // change of mode glides.
    final ease = 1 - math.exp(-40 * dt);
    state._reach += (_target(t, l).clamp(0.0, 1.0) - state._reach) * ease;
    final rest = w.mode == ArtMode.idle ? 1.0 : 0.0;
    state._rest += (rest - state._rest) * (1 - math.exp(-8 * dt));

    final area = w.box ?? Offset.zero & size;
    final compact = w.compact;
    final scale = compact
        ? math.min(area.width / _plateW, area.height / _plateH)
        : math.min(area.width / _artW, area.height / _artH) * 0.96;
    if (scale <= 0) return;
    canvas.save();
    canvas.translate(area.center.dx, area.center.dy);
    canvas.scale(scale);
    if (compact) {
      // The plate, the columns above the countdown bar inside it.
      final plate = Rect.fromCenter(
        center: Offset.zero,
        width: _plateW,
        height: _plateH,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(plate, const Radius.circular(48)),
        Paint()..color = const Color(0xF0080202),
      );
      canvas.translate(-_artW / 2, plate.top + _pad);
    } else {
      canvas.translate(-_artW / 2, -_artH / 2);
    }

    // Each lit block's brightness, from the centre column's reach: the
    // outer two stand one block short of it at each end. At rest only the
    // middles glow, slowly breathing.
    final centre = state._reach * ((_rows[1] - 1) / 2 + 0.5);
    final breath = 0.2 + 0.1 * math.sin(t * 1.6);
    final still = state._rest;
    final sprite = state.sprite((scale * pixelRatio).clamp(0.25, 4.0));
    final k = state._spritePx;
    final transforms = state._transforms;
    final tints = state._tints;
    var n = 0;
    for (var c = 0; c < 3; c++) {
      final rows = _rows[c];
      final middle = (rows - 1) / 2;
      final left = c * (_columnWidth + _columnGap);
      final top = (_artH - (rows * _pitch - (_pitch - _segment))) / 2;
      final span = c == 1 ? centre : math.max(0.0, centre - 1);
      for (var r = 0; r < rows; r++) {
        final distance = (r - middle).abs();
        final on = (span - distance + 0.5).clamp(0.0, 1.0);
        // The brightest at the middle, fading toward the tips.
        final tone = 1 - 0.9 * (distance / (span + 1)).clamp(0.0, 1.0);
        final idle = distance < 0.5 ? breath : 0.0;
        final level = tone * on * (1 - still) + idle * still;
        if (level <= 0.01) continue;
        transforms
          ..[n * 4] = 1 / k
          ..[n * 4 + 1] = 0
          ..[n * 4 + 2] = left - _margin
          ..[n * 4 + 3] = top + r * _pitch - _margin;
        tints[n] = ((level.clamp(0.0, 1.0) * 255).round() << 24 | 0xFFFFFF)
            .toSigned(32);
        n++;
      }
    }
    if (n > 0) {
      canvas.drawRawAtlas(
        sprite,
        Float32List.sublistView(transforms, 0, n * 4),
        Float32List.sublistView(state._rects, 0, n * 4),
        Int32List.sublistView(tints, 0, n),
        BlendMode.modulate,
        null,
        _atlas,
      );
    }

    // Docked, the bar under the columns shrinks toward the middle as the
    // conversation ends.
    final countdown = w.countdown;
    if (compact && countdown != null) {
      final left = countdown.value.clamp(0.0, 1.0);
      final y = _artH + _barGap;
      const bar = Radius.circular(_barHeight / 2);
      canvas.drawRRect(
        RRect.fromLTRBR(0, y, _artW, y + _barHeight, bar),
        Paint()..color = _red.withValues(alpha: 0.2),
      );
      if (left > 0) {
        final half = _artW / 2 * left;
        canvas.drawRRect(
          RRect.fromLTRBR(
            _artW / 2 - half,
            y,
            _artW / 2 + half,
            y + _barHeight,
            bar,
          ),
          Paint()..color = _red,
        );
      }
    }
    canvas.restore();
    ArtCost.paint(watch);
  }

  @override
  bool shouldRepaint(_KittPainter old) => true;
}
