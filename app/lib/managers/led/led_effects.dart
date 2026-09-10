import 'dart:math';

/// r/g/b, each 0..255.
typedef Rgb = (int r, int g, int b);

/// One frame of a running light effect. A fresh instance is created each
/// time an effect starts (state resets cleanly), and [tick] is called on
/// its own [updateInterval] with milliseconds elapsed since that start —
/// every effect below only ever uses *differences* in time (matching the
/// `millis()` semantics of the ESPHome lambda effects this was ported
/// from), so an elapsed-since-start counter is a safe stand-in for device
/// uptime. [base] is the light's last real (non-effect) color — the color
/// an effect animates around, or restores when cleared.
abstract class LedEffect {
  Duration get updateInterval;
  Rgb tick(int elapsedMs, Rgb base);
}

// ── Shared color math ──────────────────────────────────────────────────
//
// Ported 1:1 from common/light_effects_helpers.h (HA host, esphome config)
// — the same helpers accent_light_nonaddressable_effects.yaml's effects
// use, so results match that reference exactly.

/// HSV (0..1 each) -> RGB (0..1 each).
(double, double, double) _hsvToRgb(double h, double s, double v) {
  h = h % 1.0;
  if (h < 0) h += 1.0;
  final i = (h * 6.0).floor();
  final f = h * 6.0 - i;
  final p = v * (1.0 - s);
  final q = v * (1.0 - f * s);
  final w = v * (1.0 - (1.0 - f) * s);
  switch (i % 6) {
    case 0:
      return (v, w, p);
    case 1:
      return (q, v, p);
    case 2:
      return (p, v, w);
    case 3:
      return (p, q, v);
    case 4:
      return (w, p, v);
    default:
      return (v, p, q);
  }
}

/// Looks up a fractional position (0..16, wrapping) in a 16-entry RGB
/// palette (each entry 0..255) and linearly interpolates the two nearest
/// entries. Output 0..255 each (not clamped/rounded — callers do that).
(double, double, double) _lerpPalette16(List<List<int>> pal, double pos) {
  final idx0 = pos.toInt();
  final idx1 = (idx0 + 1) % 16;
  final frac = pos - idx0;
  final r = pal[idx0][0] * (1 - frac) + pal[idx1][0] * frac;
  final g = pal[idx0][1] * (1 - frac) + pal[idx1][1] * frac;
  final b = pal[idx0][2] * (1 - frac) + pal[idx1][2] * frac;
  return (r, g, b);
}

int _r255(num v) => v.round().clamp(0, 255);

// ── Effects ─────────────────────────────────────────────────────────────

class FairytwinkleEffect extends LedEffect {
  static const _pal = [
    [255, 214, 140], [255, 200, 150], [255, 190, 170], [255, 180, 195],
    [250, 175, 215], [240, 175, 230], [225, 180, 240], [205, 185, 245],
    [185, 195, 250], [165, 205, 250], [150, 215, 250], [140, 225, 245],
    [150, 230, 235], [170, 235, 225], [200, 240, 215], [230, 245, 210],
  ];
  static const _fadeInMs = 800, _fadeOutMs = 1200;
  static const _minHoldMs = 1500, _maxHoldMs = 4000;
  static const _minPauseMs = 1000, _maxPauseMs = 3000;
  final _rnd = Random();

  @override
  Duration get updateInterval => const Duration(milliseconds: 40);

  int _state = 0;
  int _stateStart = 0;
  int _nextMs = 0;
  int _holdMs = 0;
  double _hue = 0.0;

  @override
  Rgb tick(int nowMs, Rgb base) {
    var brightness = 0.0;
    if (_state == 0) {
      if (nowMs >= _nextMs) {
        _hue = _rnd.nextInt(1000) / 1000.0;
        _state = 1;
        _stateStart = nowMs;
        _holdMs = _minHoldMs + _rnd.nextInt(_maxHoldMs - _minHoldMs);
      }
    } else if (_state == 1) {
      brightness = (nowMs - _stateStart) / _fadeInMs;
      if (brightness >= 1.0) {
        brightness = 1.0;
        _state = 2;
        _stateStart = nowMs;
      }
    } else if (_state == 2) {
      brightness = 1.0;
      if (nowMs - _stateStart >= _holdMs) {
        _state = 3;
        _stateStart = nowMs;
      }
    } else if (_state == 3) {
      brightness = 1.0 - (nowMs - _stateStart) / _fadeOutMs;
      if (brightness <= 0.0) {
        brightness = 0.0;
        _state = 0;
        _nextMs = nowMs + _minPauseMs + _rnd.nextInt(_maxPauseMs - _minPauseMs);
      }
    }
    final (r, g, b) = _lerpPalette16(_pal, _hue * 15.0);
    return (_r255(r * brightness), _r255(g * brightness), _r255(b * brightness));
  }
}

class FireworksBurstEffect extends LedEffect {
  static const _launchMs = 600, _decayMs = 900;
  static const _minPauseMs = 1500, _maxPauseMs = 4000;
  final _rnd = Random();

  @override
  Duration get updateInterval => const Duration(milliseconds: 20);

  int _state = 0;
  int _stateStart = 0;
  int _nextMs = 0;
  double _hue = 0.0;

  @override
  Rgb tick(int nowMs, Rgb base) {
    double r = 0, g = 0, b = 0;
    if (_state == 0) {
      if (nowMs >= _nextMs) {
        _state = 1;
        _stateStart = nowMs;
        _hue = _rnd.nextInt(1000) / 1000.0;
      }
    } else if (_state == 1) {
      final t = (nowMs - _stateStart) / _launchMs;
      if (t >= 1.0) {
        _state = 2;
        _stateStart = nowMs;
      } else {
        final level = t * 0.4;
        r = g = b = level * 255.0;
      }
    } else if (_state == 2) {
      final t = (nowMs - _stateStart) / _decayMs;
      if (t >= 1.0) {
        _state = 0;
        _nextMs = nowMs + _minPauseMs + _rnd.nextInt(_maxPauseMs - _minPauseMs);
      } else {
        final decay = pow(1.0 - t, 2.0).toDouble();
        final (rf, gf, bf) = _hsvToRgb(_hue, 1.0, decay);
        r = rf * 255.0;
        g = gf * 255.0;
        b = bf * 255.0;
      }
    }
    return (_r255(r), _r255(g), _r255(b));
  }
}

class BeaconPulseEffect extends LedEffect {
  static const _ambR = 2, _ambG = 2, _ambB = 6;
  static const _beamR = 255, _beamG = 220, _beamB = 140;
  static const _period = 3.0, _flashWidth = 0.15;

  @override
  Duration get updateInterval => const Duration(milliseconds: 30);

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    final phase = (t % _period) / _period;
    var d = phase;
    if (d > 0.5) d = 1.0 - d;
    final flash = exp(-(d * d) / (2.0 * _flashWidth * _flashWidth));
    return (
      _r255(_ambR + (_beamR - _ambR) * flash),
      _r255(_ambG + (_beamG - _ambG) * flash),
      _r255(_ambB + (_beamB - _ambB) * flash),
    );
  }
}

class HeartbeatPulseEffect extends LedEffect {
  static const _period = 1.0; // 60 BPM
  static const _lubCenter = 0.08, _lubWidth = 0.05, _lubStrength = 1.0;
  static const _dubCenter = 0.22, _dubWidth = 0.04, _dubStrength = 0.6;
  static const _minLevel = 0.03;
  static const _heartR = 200, _heartG = 10, _heartB = 30;

  @override
  Duration get updateInterval => const Duration(milliseconds: 20);

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    var phase = (t % _period) / _period;
    if (phase < 0) phase += 1.0;
    final dl = phase - _lubCenter;
    final lub = exp(-(dl * dl) / (2.0 * _lubWidth * _lubWidth)) * _lubStrength;
    final dd = phase - _dubCenter;
    final dub = exp(-(dd * dd) / (2.0 * _dubWidth * _dubWidth)) * _dubStrength;
    final intensity = min(lub + dub, 1.0);
    final level = _minLevel + (1.0 - _minLevel) * intensity;
    return (_r255(_heartR * level), _r255(_heartG * level), _r255(_heartB * level));
  }
}

class SoftGlowEffect extends LedEffect {
  static const _breathePeriod = 8.0, _minLevel = 0.55, _easeCurve = 1.5;

  @override
  Duration get updateInterval => const Duration(milliseconds: 30);

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    var breathe = sin((t / _breathePeriod) * 6.2831853) * 0.5 + 0.5;
    breathe = pow(breathe, _easeCurve).toDouble();
    final level = _minLevel + (1.0 - _minLevel) * breathe;
    final (br, bg, bb) = base;
    return (_r255(br * level), _r255(bg * level), _r255(bb * level));
  }
}

class RollingFogEffect extends LedEffect {
  static const _pal = [
    [10, 12, 14], [20, 22, 25], [35, 37, 40], [50, 53, 58],
    [65, 68, 74], [80, 84, 92], [95, 100, 108], [110, 115, 124],
    [125, 130, 140], [140, 146, 156], [158, 164, 174], [176, 182, 192],
    [195, 200, 208], [212, 216, 222], [228, 231, 236], [245, 247, 250],
  ];

  @override
  Duration get updateInterval => const Duration(milliseconds: 30);

  double _noise1d(double x) =>
      sin(x * 1.0) * 0.500 +
      sin(x * 2.13 + 1.7) * 0.250 +
      sin(x * 4.07 + 3.1) * 0.125 +
      sin(x * 8.53 + 0.6) * 0.0625;

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    final thickness = 0.35 + 0.65 * (sin(t * 0.03) * 0.5 + 0.5);
    const contrast = 1.6;
    final combined =
        _noise1d(t * 1.3) * 0.55 + _noise1d(-t * 0.9 + 5.2) * 0.30 + _noise1d(t * 1.8 + 2.7) * 0.15;
    var v = combined * 0.5 + 0.5;
    v *= thickness;
    v = (0.5 + (v - 0.5) * contrast).clamp(0.0, 1.0);
    final (r, g, b) = _lerpPalette16(_pal, v * 15.0);
    return (_r255(r), _r255(g), _r255(b));
  }
}

/// Shared structure behind all three Pacifica variants — four drifting
/// palette waves plus a random foam sparkle, tuned per-variant by the
/// concrete subclasses below. The source YAML never abstracted this (each
/// variant is a standalone lambda), but the logic is identical apart from
/// the tuning constants, so it's factored out here to avoid transcribing
/// the same ~50 lines three times with more chances to slip up.
abstract class _PacificaEffect extends LedEffect {
  List<List<int>> get palDeep;
  List<List<int>> get palMid;
  List<List<int>> get palBright;
  List<double> get speedBase; // [s1, s2, s3, s4]
  List<double> get speedAmp;
  List<double> get speedPeriodMs;
  double get w1Mult;
  double get w2Mult;
  double get w3Pow;
  double get w3Mult;
  double get w4Pow;
  double get w4Mult;
  double get foamDecay;
  int get foamChancePer1000;
  int get foamAddMin;
  int get foamAddRange;
  double get foamMax;

  @override
  Duration get updateInterval => const Duration(milliseconds: 100);

  double _t1 = 0, _t2 = 0, _t3 = 0, _t4 = 0, _foam = 0;
  int? _lastMs;
  final _rnd = Random();

  @override
  Rgb tick(int nowMs, Rgb base) {
    _lastMs ??= nowMs;
    var dt = (nowMs - _lastMs!) / 1000.0;
    _lastMs = nowMs;
    if (dt > 0.5) dt = 0.1;

    final speed1 = speedBase[0] + speedAmp[0] * sin(nowMs / speedPeriodMs[0]);
    final speed2 = speedBase[1] + speedAmp[1] * sin(nowMs / speedPeriodMs[1] + 1.0);
    final speed3 = speedBase[2] + speedAmp[2] * sin(nowMs / speedPeriodMs[2] + 2.0);
    final speed4 = speedBase[3] + speedAmp[3] * sin(nowMs / speedPeriodMs[3] + 3.0);
    _t1 += dt * speed1;
    _t2 += dt * speed2;
    _t3 += dt * speed3;
    _t4 += dt * speed4;

    final wave1 = sin(_t1 * 0.6) * 0.5 + 0.5;
    final wave2 = sin(-_t2 * 0.9 + 1.7) * 0.5 + 0.5;
    final wave3 = sin(_t3 * 0.4 + 3.1) * 0.5 + 0.5;
    final wave4 = sin(-_t4 * 1.2 + 4.4) * 0.5 + 0.5;

    double r = 0, g = 0, b = 0;

    var pos = (_t1 * 0.8) % 16.0;
    if (pos < 0) pos += 16.0;
    var lp = _lerpPalette16(palDeep, pos);
    r += lp.$1;
    g += lp.$2;
    b += lp.$3;

    pos = (wave1 * 16.0 + _t2 * 0.3) % 16.0;
    if (pos < 0) pos += 16.0;
    lp = _lerpPalette16(palMid, pos);
    final w1 = wave1 * w1Mult;
    r += lp.$1 * w1;
    g += lp.$2 * w1;
    b += lp.$3 * w1;

    pos = (wave2 * 16.0 + _t3 * 0.4) % 16.0;
    if (pos < 0) pos += 16.0;
    lp = _lerpPalette16(palMid, pos);
    final w2 = wave2 * w2Mult;
    r += lp.$1 * w2;
    g += lp.$2 * w2;
    b += lp.$3 * w2;

    pos = (wave3 * 16.0 + _t4 * 0.5) % 16.0;
    if (pos < 0) pos += 16.0;
    lp = _lerpPalette16(palBright, pos);
    final w3 = pow(wave3, w3Pow).toDouble() * w3Mult;
    r += lp.$1 * w3;
    g += lp.$2 * w3;
    b += lp.$3 * w3;

    final w4 = pow(wave4, w4Pow).toDouble() * w4Mult;
    r += palBright[15][0] * w4;
    g += palBright[15][1] * w4;
    b += palBright[15][2] * w4;

    _foam *= foamDecay;
    if (_rnd.nextInt(1000) < foamChancePer1000) {
      _foam += foamAddMin + _rnd.nextInt(foamAddRange);
      if (_foam > foamMax) _foam = foamMax;
    }
    r += _foam;
    g += _foam;
    b += _foam;

    return (_r255(r.clamp(0, 255)), _r255(g.clamp(0, 255)), _r255(b.clamp(0, 255)));
  }
}

class PacificaCalmLagoonEffect extends _PacificaEffect {
  @override
  List<List<int>> get palDeep => const [
    [5, 40, 42], [6, 48, 50], [8, 58, 60], [10, 68, 70],
    [12, 78, 80], [15, 90, 92], [18, 102, 104], [22, 115, 117],
    [28, 128, 130], [35, 142, 144], [45, 156, 158], [58, 170, 172],
    [75, 185, 187], [95, 200, 200], [120, 215, 213], [150, 230, 225],
  ];
  @override
  List<List<int>> get palMid => const [
    [10, 60, 62], [14, 72, 74], [18, 85, 87], [24, 98, 100],
    [30, 112, 114], [38, 126, 128], [48, 140, 142], [60, 155, 155],
    [75, 170, 168], [92, 185, 180], [112, 198, 190], [135, 210, 198],
    [160, 222, 205], [188, 232, 212], [215, 242, 220], [240, 250, 232],
  ];
  @override
  List<List<int>> get palBright => const [
    [40, 140, 140], [60, 160, 158], [85, 180, 175], [112, 198, 190],
    [140, 213, 202], [168, 225, 212], [195, 235, 222], [215, 242, 230],
    [230, 247, 238], [240, 250, 244], [247, 252, 248], [250, 253, 250],
    [252, 254, 252], [253, 254, 253], [254, 255, 254], [255, 255, 255],
  ];
  @override
  List<double> get speedBase => const [3.5, 2.5, 2.0, 1.2];
  @override
  List<double> get speedAmp => const [2.0, 1.5, 1.0, 0.8];
  @override
  List<double> get speedPeriodMs => const [9000, 13000, 17000, 21000];
  @override
  double get w1Mult => 0.55;
  @override
  double get w2Mult => 0.45;
  @override
  double get w3Pow => 3.0;
  @override
  double get w3Mult => 0.5;
  @override
  double get w4Pow => 4.0;
  @override
  double get w4Mult => 0.35;
  @override
  double get foamDecay => 0.85;
  @override
  int get foamChancePer1000 => 15;
  @override
  int get foamAddMin => 20;
  @override
  int get foamAddRange => 40;
  @override
  double get foamMax => 80;
}

class PacificaStormEffect extends _PacificaEffect {
  @override
  List<List<int>> get palDeep => const [
    [2, 3, 6], [3, 4, 8], [4, 6, 11], [5, 8, 14],
    [6, 10, 18], [8, 13, 23], [10, 17, 29], [13, 22, 36],
    [17, 28, 44], [22, 36, 54], [28, 46, 66], [36, 58, 80],
    [46, 72, 95], [58, 88, 110], [72, 104, 124], [88, 120, 138],
  ];
  @override
  List<List<int>> get palMid => const [
    [4, 6, 10], [6, 9, 15], [9, 13, 21], [13, 18, 28],
    [18, 24, 36], [24, 32, 46], [32, 42, 58], [42, 54, 72],
    [54, 68, 88], [68, 84, 104], [85, 102, 120], [104, 120, 136],
    [125, 138, 150], [148, 156, 162], [172, 174, 174], [195, 192, 186],
  ];
  @override
  List<List<int>> get palBright => const [
    [20, 24, 30], [35, 40, 48], [55, 62, 70], [78, 86, 94],
    [104, 112, 118], [132, 138, 142], [160, 164, 166], [186, 188, 188],
    [206, 208, 206], [222, 224, 220], [234, 236, 232], [242, 244, 240],
    [247, 249, 246], [250, 252, 249], [253, 254, 252], [255, 255, 255],
  ];
  @override
  List<double> get speedBase => const [10.0, 7.0, 5.0, 3.5];
  @override
  List<double> get speedAmp => const [6.0, 5.0, 3.0, 2.5];
  @override
  List<double> get speedPeriodMs => const [6000, 9000, 12000, 15000];
  @override
  double get w1Mult => 0.65;
  @override
  double get w2Mult => 0.55;
  @override
  double get w3Pow => 2.2;
  @override
  double get w3Mult => 0.85;
  @override
  double get w4Pow => 3.0;
  @override
  double get w4Mult => 0.65;
  @override
  double get foamDecay => 0.80;
  @override
  int get foamChancePer1000 => 40;
  @override
  int get foamAddMin => 80;
  @override
  int get foamAddRange => 140;
  @override
  double get foamMax => 220;
}

class PacificaDeepCurrentEffect extends _PacificaEffect {
  @override
  List<List<int>> get palDeep => const [
    [0, 1, 4], [0, 1, 6], [0, 2, 8], [0, 2, 10],
    [0, 3, 13], [0, 4, 16], [1, 5, 20], [1, 6, 24],
    [2, 8, 29], [3, 10, 34], [4, 13, 40], [6, 17, 47],
    [9, 22, 54], [13, 28, 62], [18, 36, 70], [24, 45, 78],
  ];
  @override
  List<List<int>> get palMid => const [
    [1, 2, 8], [2, 3, 12], [3, 5, 17], [4, 7, 23],
    [6, 10, 30], [8, 14, 38], [11, 19, 47], [15, 25, 57],
    [20, 32, 68], [27, 41, 80], [35, 52, 92], [45, 65, 105],
    [58, 80, 118], [73, 97, 130], [92, 116, 142], [114, 137, 154],
  ];
  @override
  List<List<int>> get palBright => const [
    [3, 4, 15], [5, 7, 22], [8, 11, 31], [12, 17, 42],
    [18, 25, 54], [25, 35, 68], [34, 47, 83], [45, 62, 99],
    [58, 79, 115], [74, 98, 131], [92, 118, 146], [113, 138, 160],
    [136, 158, 172], [160, 177, 183], [186, 196, 193], [212, 215, 206],
  ];
  @override
  List<double> get speedBase => const [4.0, 3.0, 2.0, 1.2];
  @override
  List<double> get speedAmp => const [2.0, 1.5, 1.0, 0.6];
  @override
  List<double> get speedPeriodMs => const [11000, 15000, 19000, 23000];
  @override
  double get w1Mult => 0.45;
  @override
  double get w2Mult => 0.35;
  @override
  double get w3Pow => 4.5;
  @override
  double get w3Mult => 0.40;
  @override
  double get w4Pow => 5.0;
  @override
  double get w4Mult => 0.25;
  @override
  double get foamDecay => 0.90;
  @override
  int get foamChancePer1000 => 4;
  @override
  int get foamAddMin => 10;
  @override
  int get foamAddRange => 20;
  @override
  double get foamMax => 50;
}

/// Shared structure behind all three Aurora variants: one drifting palette
/// scan plus a slow breathing scale, tuned per-variant below.
abstract class _AuroraEffect extends LedEffect {
  List<List<int>> get pal;
  double get hueSpeed;
  double get breathePeriodHz; // multiplies t inside sin(t * this)
  double get breathePow;
  double get scaleMin;
  double get scaleRange;

  @override
  Duration get updateInterval;

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    var huePos = (t * hueSpeed) % 16.0;
    if (huePos < 0) huePos += 16.0;
    var breathing = sin(t * breathePeriodHz) * 0.5 + 0.5;
    breathing = pow(breathing, breathePow).toDouble();
    final scale = scaleMin + scaleRange * breathing;
    final (r, g, b) = _lerpPalette16(pal, huePos);
    return (_r255(r * scale), _r255(g * scale), _r255(b * scale));
  }
}

class AuroraSolarStormEffect extends _AuroraEffect {
  @override
  Duration get updateInterval => const Duration(milliseconds: 30);
  @override
  List<List<int>> get pal => const [
    [0, 40, 10], [0, 70, 20], [10, 100, 30], [20, 140, 40],
    [40, 180, 60], [60, 210, 90], [50, 200, 130], [40, 180, 170],
    [30, 150, 200], [40, 120, 210], [70, 90, 210], [110, 70, 200],
    [150, 60, 190], [190, 60, 170], [210, 70, 140], [180, 90, 120],
  ];
  @override
  double get hueSpeed => 0.55;
  @override
  double get breathePeriodHz => 0.35;
  @override
  double get breathePow => 1.1;
  @override
  double get scaleMin => 0.35;
  @override
  double get scaleRange => 0.65;
}

class AuroraPastelDreamEffect extends _AuroraEffect {
  @override
  Duration get updateInterval => const Duration(milliseconds: 40);
  @override
  List<List<int>> get pal => const [
    [140, 190, 155], [140, 205, 165], [145, 215, 170], [150, 225, 175],
    [160, 235, 185], [170, 245, 200], [165, 240, 215], [160, 230, 225],
    [155, 215, 235], [160, 200, 235], [175, 190, 235], [195, 180, 230],
    [210, 175, 225], [225, 175, 220], [235, 180, 210], [220, 185, 200],
  ];
  @override
  double get hueSpeed => 0.06;
  @override
  double get breathePeriodHz => 0.06;
  @override
  double get breathePow => 2.0;
  @override
  double get scaleMin => 0.45;
  @override
  double get scaleRange => 0.35;
}

class AuroraRedSkyEffect extends _AuroraEffect {
  @override
  Duration get updateInterval => const Duration(milliseconds: 40);
  @override
  List<List<int>> get pal => const [
    [20, 0, 5], [35, 0, 8], [55, 0, 12], [80, 2, 18],
    [105, 5, 25], [130, 10, 35], [150, 20, 50], [170, 35, 68],
    [185, 55, 90], [195, 80, 115], [200, 105, 140], [205, 130, 160],
    [210, 150, 175], [215, 170, 190], [220, 190, 205], [225, 205, 215],
  ];
  @override
  double get hueSpeed => 0.15;
  @override
  double get breathePeriodHz => 0.12;
  @override
  double get breathePow => 1.3;
  @override
  double get scaleMin => 0.15;
  @override
  double get scaleRange => 0.85;
}

class BubblesEffect extends LedEffect {
  static const _pauseMin = 500, _pauseMax = 2000;
  static const _lifeMin = 2000, _lifeMax = 5000;
  static const _popDecayRate = 3.0;
  static const _maxBrightness = 0.5;
  final _rnd = Random();

  @override
  Duration get updateInterval => const Duration(milliseconds: 40);

  int _state = 0;
  int _stateStart = 0;
  double _hue = 0.5;
  double _popFlash = 0.0;
  int _pauseDuration = 0;
  int _lifeDuration = 0;
  int? _lastMs;

  @override
  Rgb tick(int nowMs, Rgb base) {
    _lastMs ??= nowMs;
    var dt = (nowMs - _lastMs!) / 1000.0;
    _lastMs = nowMs;
    if (dt > 0.2) dt = 0.02;

    if (_state == 0) {
      if (nowMs - _stateStart >= _pauseDuration) {
        _state = 1;
        _stateStart = nowMs;
        _hue = 0.5 + _rnd.nextInt(250) / 1000.0;
        _lifeDuration = _lifeMin + _rnd.nextInt(_lifeMax - _lifeMin);
      }
    } else if (_state == 1) {
      if (nowMs - _stateStart >= _lifeDuration) {
        _state = 2;
        _stateStart = nowMs;
        _popFlash = 1.0;
      }
    } else if (_state == 2) {
      _popFlash -= dt * _popDecayRate;
      if (_popFlash <= 0.0) {
        _popFlash = 0.0;
        _state = 0;
        _stateStart = nowMs;
        _pauseDuration = _pauseMin + _rnd.nextInt(_pauseMax - _pauseMin);
      }
    }

    var r = 0.0, g = 0.0, b = 0.0;
    if (_state == 1) {
      final (rf, gf, bf) = _hsvToRgb(_hue, 0.35, _maxBrightness);
      r = rf;
      g = gf;
      b = bf;
    } else if (_state == 2) {
      final (rf, gf, bf) = _hsvToRgb(_hue, 0.15, _popFlash);
      r = rf;
      g = gf;
      b = bf;
    }
    return (_r255(r * 255), _r255(g * 255), _r255(b * 255));
  }
}

class DiscoSparkleEffect extends LedEffect {
  static const _baseBrightness = 0.25;
  static const _flashChancePer1000 = 8;
  final _rnd = Random();

  @override
  Duration get updateInterval => const Duration(milliseconds: 30);

  double _flash = 0.0;

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    final hue = (t * 0.05) % 1.0;
    final (br, bg, bb) = _hsvToRgb(hue, 0.8, _baseBrightness);
    _flash *= 0.75;
    if (_rnd.nextInt(1000) < _flashChancePer1000) _flash = 1.0;
    final r = br * (1 - _flash) + _flash;
    final g = bg * (1 - _flash) + _flash;
    final b = bb * (1 - _flash) + _flash;
    return (_r255(r * 255), _r255(g * 255), _r255(b * 255));
  }
}

// ── white_effects.yaml adaptations ─────────────────────────────────────
//
// That file's effects drive real warm/cold-white channels
// (id(warm_output)/id(cold_output)) our hardware doesn't have. Adapted by
// mixing a fixed warm tint and a fixed cool tint proportionally to each
// effect's own ww/cw levels — same brightness math as the source, just a
// color mix standing in for a literal white channel.
const _warmTint = (255, 147, 41); // ~2000K, same tint as CandleFlickerEffect
const _coolTint = (200, 220, 255); // ~6500K blue-white

Rgb _mixWarmCool(double ww, double cw) {
  final (wr, wg, wb) = _warmTint;
  final (cr, cg, cb) = _coolTint;
  return (
    _r255(wr * ww + cr * cw),
    _r255(wg * ww + cg * cw),
    _r255(wb * ww + cb * cw),
  );
}

/// Slow multi-keyframe warm↔cool cycle simulating a day — warm dominates
/// dawn/dusk, cool dominates midday. 300s per full cycle by default (the
/// source's own default; its comment notes 86400 for a literal 24h day).
class SunriseSunsetEffect extends LedEffect {
  static const _totalCycleSeconds = 300.0;
  // {phase 0..1, warm 0..1, cool 0..1}
  static const _kp = [
    [0.00, 0.00, 0.00], // deep night
    [0.18, 0.05, 0.00], // pre-dawn twilight
    [0.25, 0.35, 0.02], // first light
    [0.32, 0.55, 0.05], // sunrise glow, warm-dominant
    [0.40, 0.55, 0.30], // morning
    [0.50, 0.35, 0.75], // midday, cool-dominant daylight
    [0.62, 0.55, 0.30], // afternoon
    [0.72, 0.60, 0.05], // sunset glow, warm-dominant
    [0.80, 0.30, 0.00], // dusk
    [0.88, 0.05, 0.00], // late twilight
    [1.00, 0.00, 0.00], // back to night (wraps to phase 0)
  ];

  @override
  Duration get updateInterval => const Duration(seconds: 5);

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    var phase = (t % _totalCycleSeconds) / _totalCycleSeconds;
    if (phase < 0.0) phase += 1.0;

    var ww = _kp[0][1], cw = _kp[0][2];
    for (var k = 0; k < _kp.length - 1; k++) {
      if (phase >= _kp[k][0] && phase <= _kp[k + 1][0]) {
        final span = _kp[k + 1][0] - _kp[k][0];
        final frac = span > 0.0 ? (phase - _kp[k][0]) / span : 0.0;
        ww = _kp[k][1] * (1 - frac) + _kp[k + 1][1] * frac;
        cw = _kp[k][2] * (1 - frac) + _kp[k + 1][2] * frac;
        break;
      }
    }
    return _mixWarmCool(ww, cw);
  }
}

/// Slow, dim cool-tint breathing — a calmer, cooler-toned counterpart to
/// [SoftGlowEffect] (which breathes the *current* base color instead of a
/// fixed tint).
class MoonlightGlowEffect extends LedEffect {
  static const _breathePeriod = 10.0, _minLevel = 0.15, _maxLevel = 0.50, _easeCurve = 1.5;

  @override
  Duration get updateInterval => const Duration(milliseconds: 30);

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    var breathe = sin((t / _breathePeriod) * 6.2831853) * 0.5 + 0.5;
    breathe = pow(breathe, _easeCurve).toDouble();
    final level = _minLevel + (_maxLevel - _minLevel) * breathe;
    return _mixWarmCool(0.0, level);
  }
}

/// Dim warm ambient shimmer, interrupted by irregular bursts of 1..3 bright
/// cool-white sub-flashes ("strikes") — a storm at a distance.
class LightningStormEffect extends LedEffect {
  final _rnd = Random();

  @override
  Duration get updateInterval => const Duration(milliseconds: 20);

  double _flash = 0.0;
  int _pending = 0;
  int _nextMs = 0;

  double _noise1d(double x) =>
      sin(x * 1.0) * 0.500 +
      sin(x * 2.13 + 1.7) * 0.250 +
      sin(x * 4.07 + 3.1) * 0.125 +
      sin(x * 8.53 + 0.6) * 0.0625;

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    final amb = 0.02 + 0.03 * (_noise1d(t * 0.5) * 0.5 + 0.5);

    _flash *= 0.72;
    if (_pending == 0 && _rnd.nextInt(2000) < 4) {
      _pending = 1 + _rnd.nextInt(3);
      _nextMs = nowMs;
    }
    if (_pending > 0 && nowMs >= _nextMs) {
      _flash = 0.85 + _rnd.nextInt(150) / 1000.0;
      _pending--;
      _nextMs = nowMs + 50 + _rnd.nextInt(100);
    }
    if (_flash > 1.0) _flash = 1.0;

    return _mixWarmCool(amb, _flash);
  }
}

/// One-shot 10-minute ramp from off to full brightness — warm rises first
/// (first half), then cool rises while warm recedes slightly but stays
/// present (second half) — then holds at the final level once the ramp
/// completes, rather than looping. `nowMs` is elapsed-since-this-effect-
/// started (see [LedEffect]'s class doc), which is exactly the "time since
/// alarm armed" this needs.
class WakeUpAlarmEffect extends LedEffect {
  static const _durationS = 600.0;

  @override
  Duration get updateInterval => const Duration(seconds: 2);

  @override
  Rgb tick(int nowMs, Rgb base) {
    var t = (nowMs / 1000.0) / _durationS;
    if (t > 1.0) t = 1.0;

    double ww, cw;
    if (t < 0.5) {
      final local = t / 0.5;
      ww = local;
      cw = 0.0;
    } else {
      final local = (t - 0.5) / 0.5;
      ww = 1.0 - local * 0.4;
      cw = local;
    }
    return _mixWarmCool(ww, cw);
  }
}

/// Ported from white_effects.yaml's "Candle Flicker (Warm White)" — that
/// version drives real warm/cold-white channels our hardware doesn't have
/// (id(warm_output)/id(cold_output)), at brightness only, no color of its
/// own. Adapted to RGB by keeping its exact brightness curve (noise +
/// occasional decaying "gust" dips, floored so the candle never fully
/// goes dark) and applying it to a fixed warm-candle tint instead of a
/// bare white channel.
class CandleFlickerEffect extends LedEffect {
  static const _warmR = 255, _warmG = 147, _warmB = 41; // ~2000K candle tint
  final _rnd = Random();

  @override
  Duration get updateInterval => const Duration(milliseconds: 50);

  double _gust = 0.0;

  double _noise1d(double x) =>
      sin(x * 1.0) * 0.500 +
      sin(x * 2.13 + 1.7) * 0.250 +
      sin(x * 4.07 + 3.1) * 0.125 +
      sin(x * 8.53 + 0.6) * 0.0625;

  @override
  Rgb tick(int nowMs, Rgb base) {
    final t = nowMs / 1000.0;
    final baseFlame = _noise1d(t * 3.0) * 0.5 + 0.5;
    final micro = _noise1d(t * 11.3 + 2.0) * 0.5 + 0.5;
    var v = baseFlame * 0.70 + micro * 0.30;

    _gust *= 0.90;
    if (_rnd.nextInt(1000) < 5) {
      _gust += 0.30 + _rnd.nextInt(300) / 1000.0;
      if (_gust > 0.65) _gust = 0.65;
    }
    v -= _gust;
    if (v < 0.12) v = 0.12; // candle never fully goes dark
    if (v > 1.0) v = 1.0;

    return (_r255(_warmR * v), _r255(_warmG * v), _r255(_warmB * v));
  }
}

/// Every named effect that isn't one of the four simple ones LedManager
/// implements inline (Pulse, Strobe, Random, Flicker) — a fresh instance
/// per entry so restarting an effect always starts from clean state.
final Map<String, LedEffect Function()> ledEffectRunners = {
  'Sunrise/Sunset': SunriseSunsetEffect.new,
  'Moonlight Glow': MoonlightGlowEffect.new,
  'Lightning Storm': LightningStormEffect.new,
  'Wake-Up Alarm': WakeUpAlarmEffect.new,
  'Candle Flicker': CandleFlickerEffect.new,
  'Fairytwinkle': FairytwinkleEffect.new,
  'Fireworks Burst': FireworksBurstEffect.new,
  'Beacon Pulse': BeaconPulseEffect.new,
  'Heartbeat Pulse': HeartbeatPulseEffect.new,
  'Soft Glow': SoftGlowEffect.new,
  'Rolling Fog (Pronounced)': RollingFogEffect.new,
  'Pacifica (Calm Lagoon)': PacificaCalmLagoonEffect.new,
  'Pacifica (Storm)': PacificaStormEffect.new,
  'Pacifica (Deep Current)': PacificaDeepCurrentEffect.new,
  'Aurora (Solar Storm)': AuroraSolarStormEffect.new,
  'Aurora (Pastel Dream)': AuroraPastelDreamEffect.new,
  'Aurora (Red Sky)': AuroraRedSkyEffect.new,
  'Bubbles': BubblesEffect.new,
  'Disco Sparkle': DiscoSparkleEffect.new,
};
