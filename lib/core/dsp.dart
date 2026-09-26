/// Filter math (RBJ cookbook biquads).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'band.dart';

/// Rate the device's biquad coefficients are designed at.
const deviceSampleRate = 96000;

final _ln10 = math.log(10);
double log10(double x) => math.log(x) / _ln10;

double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;
double _asinh(double x) => math.log(x + math.sqrt(x * x + 1));

/// (1, a1, a2, b0, b1, b2) normalized by a0, or null for an unknown type.
///
/// Inputs are clamped as in AutoEq's biquad.py.
List<double>? biquadCoeffs(
  String type,
  double freq,
  double gain,
  double q, [
  num fs = deviceSampleRate,
]) {
  final w0 = 2 * math.pi * math.max(1e-6, math.min(freq / fs, 1));
  q = math.max(1e-4, math.min(q, 1000));
  gain = math.max(-40, math.min(gain, 40));
  final sin = math.sin(w0), cos = math.cos(w0);
  final a = math.pow(10, gain / 40).toDouble();
  final alpha = sin / (2 * q);
  double a0, a1, a2, b0, b1, b2;

  switch (type) {
    case 'PK':
      a0 = 1 + alpha / a;
      a1 = -2 * cos;
      a2 = 1 - alpha / a;
      b0 = 1 + alpha * a;
      b1 = -2 * cos;
      b2 = 1 - alpha * a;
    case 'LSQ':
      final am = 2 * math.sqrt(a) * alpha;
      a0 = (a + 1) + (a - 1) * cos + am;
      a1 = -2 * ((a - 1) + (a + 1) * cos);
      a2 = (a + 1) + (a - 1) * cos - am;
      b0 = a * ((a + 1) - (a - 1) * cos + am);
      b1 = 2 * a * ((a - 1) - (a + 1) * cos);
      b2 = a * ((a + 1) - (a - 1) * cos - am);
    case 'HSQ':
      final am = 2 * math.sqrt(a) * alpha;
      a0 = (a + 1) - (a - 1) * cos + am;
      a1 = 2 * ((a - 1) - (a + 1) * cos);
      a2 = (a + 1) - (a - 1) * cos - am;
      b0 = a * ((a + 1) + (a - 1) * cos + am);
      b1 = -2 * a * ((a - 1) + (a + 1) * cos);
      b2 = a * ((a + 1) + (a - 1) * cos - am);
    case 'LP':
      a0 = 1 + alpha;
      a1 = -2 * cos;
      a2 = 1 - alpha;
      b0 = (1 - cos) / 2;
      b1 = 1 - cos;
      b2 = (1 - cos) / 2;
    case 'HP':
      a0 = 1 + alpha;
      a1 = -2 * cos;
      a2 = 1 - alpha;
      b0 = (1 + cos) / 2;
      b1 = -(1 + cos);
      b2 = (1 + cos) / 2;
    default:
      return null;
  }
  return [1.0, a1 / a0, a2 / a0, b0 / a0, b1 / a0, b2 / a0];
}

/// Per-frequency term of [gainsDb]; depends only on the grid, so hot loops
/// compute it once.
Float64List biquadPhi(List<double> freqs, num fs) {
  final out = Float64List(freqs.length);
  for (var i = 0; i < freqs.length; i++) {
    final s = math.sin(math.pi * freqs[i] / fs);
    out[i] = 4 * s * s;
  }
  return out;
}

/// Summed magnitude response (dB) of biquads [coeffs] at [biquadPhi] points.
Float64List gainsDb(Float64List phi, List<List<double>> coeffs) {
  final gains = Float64List(phi.length);
  for (final c in coeffs) {
    final a0 = c[0], a1 = c[1], a2 = c[2], b0 = c[3], b1 = c[4], b2 = c[5];
    final nk = (b0 + b1 + b2) * (b0 + b1 + b2);
    final nb = b1 * (b0 + b2) + 4 * b0 * b2;
    final nc = b0 * b2;
    final dk = (a0 + a1 + a2) * (a0 + a1 + a2);
    final db = a1 * (a0 + a2) + 4 * a0 * a2;
    final dc = a0 * a2;
    for (var i = 0; i < phi.length; i++) {
      final p = phi[i];
      final num = nk + (nc * p - nb) * p;
      final den = dk + (dc * p - db) * p;
      gains[i] +=
          10 * log10(math.max(num, 1e-12)) - 10 * log10(math.max(den, 1e-12));
    }
  }
  return gains;
}

/// Summed dB response of [filters] (any band type) at [freqs].
Float64List filtersResponseDb(
  List<double> freqs,
  List<Band> filters, [
  num fs = deviceSampleRate,
]) {
  final coeffs = <List<double>>[];
  for (final f in filters) {
    final c = biquadCoeffs(f.type, f.freq, f.gain, f.q, fs);
    if (c != null) coeffs.add(c);
  }
  return gainsDb(biquadPhi(freqs, fs), coeffs);
}

/// Q -> bandwidth in octaves.
double qToBw(double q) => 2 * _asinh(1 / (2 * math.max(q, 0.001))) / math.ln2;

/// Bandwidth in octaves -> Q, or null for absurd widths.
double? bwToQ(double bw) {
  final q = 1 / (2 * _sinh(bw * math.ln2 / 2));
  return q.isFinite && q > 0 ? q : null;
}
