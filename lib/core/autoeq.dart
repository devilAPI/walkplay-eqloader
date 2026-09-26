/// AutoEQ engine (port of hangout.audio's equalizer.js, via logic/eqloader.py).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'band.dart';
import 'dsp.dart';

// hangout.audio uses a generic 48 kHz; model the filters exactly as the
// device will run them instead, since response near the top of the band
// differs noticeably between the two rates.
const _sampleRate = deviceSampleRate;
const _trebleStartFrom = 7000.0;
const _minFreq = 20.0, _maxFreq = 15000.0;
const _minQ = 0.5, _maxQ = 2.0;
const _minGain = -12.0, _maxGain = 12.0;

/// (maxDf, maxDq, maxDg, stepDf, stepDq, stepDg) per optimizer iteration.
const _optimizeDeltas = [
  (10, 10, 10, 5.0, 0.1, 0.5),
  (10, 10, 10, 2.0, 0.1, 0.2),
  (10, 10, 10, 1.0, 0.1, 0.1),
];

/// ~1/96 octave grid from 20 Hz to 20 kHz, used for the optimizer itself.
List<double> autoeqRawFrequencies() {
  final n = (math.log(20000 / 20) / math.log(1.0072)).ceil();
  return [for (var i = 0; i < n; i++) 20 * math.pow(1.0072, i).toDouble()];
}

/// Parse a two-column (freq, gain) measurement/target text file.
///
/// Accepts whitespace- or comma-separated columns and ignores blank lines,
/// header lines and comment lines (starting with '#', '*' or ';').
List<Point> parseFrequencyResponse(String text, {String source = 'file'}) {
  final points = <Point>[];
  for (var line in text.split(RegExp(r'\r?\n'))) {
    line = line.trim();
    if (line.isEmpty || line.startsWith(RegExp(r'[#*;]'))) continue;
    final parts = line.replaceAll(',', ' ').split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final freq = double.tryParse(parts[0]);
    final gain = double.tryParse(parts[1]);
    if (freq == null || gain == null) continue;
    // A single NaN would poison every distance the optimizer computes.
    if (!freq.isFinite || !gain.isFinite || freq <= 0) continue;
    points.add((freq, gain));
  }
  if (points.isEmpty) {
    throw FormatException('No frequency/gain data found in $source');
  }
  stableSort<Point>(points, (a, b) => a.$1.compareTo(b.$1));
  return points;
}

/// Interpolate values at [fv] (ascending) from breakpoints [fr] (ascending).
///
/// Ported as-is from the JS `interp`: the scan index is shared across the
/// whole fv pass rather than reset per point.
List<Point> autoeqInterp(List<double> fv, List<Point> fr) {
  var i = 0;
  final n = fr.length;
  final out = <Point>[];
  for (final f in fv) {
    var found = false;
    while (i < n - 1) {
      final (f0, v0) = fr[i];
      final (f1, v1) = fr[i + 1];
      if (i == 0 && f < f0) {
        out.add((f, v0));
        found = true;
        break;
      } else if (f0 <= f && f < f1) {
        out.add((f, v0 + (v1 - v0) * (f - f0) / (f1 - f0)));
        found = true;
        break;
      }
      i++;
    }
    if (!found) out.add((f, fr.last.$2));
  }
  return out;
}

/// Like upstream: bands with a zero freq/gain/Q, and LP/HP, are ignored.
List<List<double>> autoeqFiltersToCoeffs(List<Band> filters) => [
  for (final f in filters)
    if (f.freq != 0 &&
        f.gain != 0 &&
        f.q != 0 &&
        (f.type == 'PK' || f.type == 'LSQ' || f.type == 'HSQ'))
      biquadCoeffs(f.type, f.freq, f.gain, f.q, _sampleRate)!,
];

/// Curve [fr] with [filters] applied.
List<Point> autoeqApply(List<Point> fr, List<Band> filters) {
  final freqs = [for (final p in fr) p.$1];
  final gains = gainsDb(
    biquadPhi(freqs, _sampleRate),
    autoeqFiltersToCoeffs(filters),
  );
  return [for (var i = 0; i < fr.length; i++) (fr[i].$1, fr[i].$2 + gains[i])];
}

/// Attenuation (<= 0 dB, floored to 0.1 dB) that keeps the EQ's peak boost
/// from clipping. Never positive: an all-cut EQ must not add gain.
double autoeqCalcPreamp(List<Point> fr1, List<Point> fr2) {
  var maxBoost = double.negativeInfinity;
  for (var i = 0; i < math.min(fr1.length, fr2.length); i++) {
    maxBoost = math.max(maxBoost, fr2[i].$2 - fr1[i].$2);
  }
  return math.min(0.0, (-maxBoost * 10).floorToDouble() / 10);
}

/// Mean absolute deviation, ignoring deviations under 0.1 dB.
double _distance(Float64List values, Float64List target) {
  var sum = 0.0;
  for (var i = 0; i < values.length; i++) {
    final d = (values[i] - target[i]).abs();
    if (d >= 0.1) sum += d;
  }
  return sum / values.length;
}

double autoeqFreqUnit(double freq) {
  if (freq < 100) return 1;
  if (freq < 1000) return 10;
  if (freq < 10000) return 100;
  return 1000;
}

/// Round bands to device-friendly values and clamp to the optimizer's ranges.
List<Band> autoeqStrip(List<Band> filters) => [
  for (final f in filters)
    Band(
      type: f.type,
      freq: (f.freq - f.freq % autoeqFreqUnit(f.freq)).floorToDouble(),
      q: ((f.q * 10).floorToDouble() / 10).clamp(_minQ, _maxQ),
      gain: ((f.gain * 10).floorToDouble() / 10).clamp(_minGain, _maxGain),
    ),
];

/// One PK candidate per contiguous region where [fr] deviates from the
/// target by >= threshold, centred on it and sized to its width.
List<Band> autoeqSearchCandidates(
  List<Point> fr,
  List<Point> frTarget,
  double threshold,
) {
  var state = 0; // 1: peak, 0: matched, -1: dip
  var startIndex = -1;
  final candidates = <Band>[];

  for (var i = 0; i < fr.length; i++) {
    final (f, v0) = fr[i];
    final delta = v0 - frTarget[i].$2;
    final nextState = delta.abs() < threshold ? 0 : (delta > 0 ? 1 : -1);
    if (nextState == state) continue;

    // Close the peak/dip region that just ended (see the Python original for
    // why this deviates from upstream's start_index toggling).
    if (state != 0 && startIndex >= 0) {
      final start = fr[startIndex].$1;
      final center = math.sqrt(start * f);
      final gain =
          autoeqInterp([center], frTarget.sublist(startIndex, i + 1))[0].$2 -
          autoeqInterp([center], fr.sublist(startIndex, i + 1))[0].$2;
      if (_minFreq <= center && center <= _maxFreq) {
        candidates.add(
          Band(type: 'PK', freq: center, q: center / (f - start), gain: gain),
        );
      }
    }
    startIndex = nextState != 0 ? i : -1;
    state = nextState;
  }
  return candidates;
}

/// A measurement and target on one grid, as arrays, so the optimizer's inner
/// loop evaluates candidate filters cheaply.
class _AutoEqFit {
  final Float64List values;
  final Float64List target;
  final Float64List phi;

  _AutoEqFit(List<Point> fr, List<Point> frTarget)
    : values = Float64List.fromList([for (final p in fr) p.$2]),
      target = Float64List.fromList([for (final p in frTarget) p.$2]),
      phi = biquadPhi([for (final p in fr) p.$1], _sampleRate);

  Float64List apply(Float64List values, List<Band> filters) {
    final g = gainsDb(phi, autoeqFiltersToCoeffs(filters));
    for (var i = 0; i < g.length; i++) {
      g[i] += values[i];
    }
    return g;
  }

  /// Distance to target after applying [filters] to [base] (default: the
  /// measurement).
  double distance(List<Band> filters, [Float64List? base]) =>
      _distance(apply(base ?? values, filters), target);
}

/// Greedy local search over each band's freq/Q/gain, one band at a time.
void _refinePass(
  _AutoEqFit fit,
  List<Band> filters,
  int iteration,
  bool reverse,
) {
  final (maxDf, maxDq, maxDg, stepDf, stepDq, stepDg) =
      _optimizeDeltas[iteration];

  final order = [for (var i = 0; i < filters.length; i++) i];
  for (final i in reverse ? order.reversed : order) {
    final f = filters[i];
    final others = fit.apply(fit.values, [
      ...filters.sublist(0, i),
      ...filters.sublist(i + 1),
    ]);
    var bestFilter = f.copy();
    var bestDistance = fit.distance([f], others);

    bool tryStep(int df, int dq, int dg) {
      final freq = f.freq + df * autoeqFreqUnit(f.freq) * stepDf;
      final q = f.q + dq * stepDq;
      final gain = f.gain + dg * stepDg;
      if (!(_minFreq <= freq &&
          freq <= _maxFreq &&
          _minQ <= q &&
          q <= _maxQ &&
          _minGain <= gain &&
          gain <= _maxGain)) {
        return false;
      }
      final candidate = Band(type: f.type, freq: freq, q: q, gain: gain);
      final distance = fit.distance([candidate], others);
      if (distance < bestDistance) {
        bestFilter = candidate;
        bestDistance = distance;
        return true;
      }
      return false;
    }

    // Loop bounds (including their asymmetry) are upstream's.
    for (var df = -maxDf; df < maxDf; df++) {
      for (var dq = maxDq - 1; dq > -maxDq - 1; dq--) {
        // smaller Q (wider) first
        for (var dg = 1; dg < maxDg; dg++) {
          if (!tryStep(df, dq, dg)) break;
        }
        for (var dg = -1; dg > -maxDg - 1; dg--) {
          if (!tryStep(df, dq, dg)) break;
        }
      }
    }
    filters[i] = bestFilter;
  }
}

/// Refine forward then backward, then merge near-duplicates and drop bands
/// that don't help.
List<Band> _optimize(_AutoEqFit fit, List<Band> filters, int iteration) {
  for (final reverse in [false, true]) {
    filters = autoeqStrip(filters);
    _refinePass(fit, filters, iteration, reverse);
  }
  stableSort<Band>(filters, (a, b) => a.freq.compareTo(b.freq));

  var i = 0;
  while (i < filters.length - 1) {
    final f1 = filters[i], f2 = filters[i + 1];
    if ((f1.freq - f2.freq).abs() <= autoeqFreqUnit(f1.freq) &&
        (f1.q - f2.q).abs() <= 0.1) {
      f1.gain += f2.gain;
      filters.removeAt(i + 1);
    } else {
      i++;
    }
  }

  var bestDistance = fit.distance(filters);
  i = 0;
  while (i < filters.length) {
    if (filters[i].gain.abs() <= 0.1) {
      filters.removeAt(i);
      continue;
    }
    final distance = fit.distance([
      ...filters.sublist(0, i),
      ...filters.sublist(i + 1),
    ]);
    if (distance < bestDistance) {
      filters.removeAt(i);
      bestDistance = distance;
    } else {
      i++;
    }
  }
  return filters;
}

/// Compute up to [maxFilters] PK filters that reshape [fr] towards
/// [frTarget] (curves on the same ascending grid, level-aligned).
List<Band> autoeqRun(List<Point> fr, List<Point> frTarget, int maxFilters) {
  if (maxFilters <= 0) return [];
  final iterations = [for (var i = 0; i < _optimizeDeltas.length; i++) i];

  List<Band> widest(List<Band> candidates, int count) {
    final byQ = [...candidates];
    stableSort<Band>(byQ, (a, b) => a.q.compareTo(b.q));
    final picked = byQ.take(math.max(0, count)).toList();
    stableSort<Band>(picked, (a, b) => a.freq.compareTo(b.freq));
    return picked;
  }

  final fit = _AutoEqFit(fr, frTarget);
  var first = widest([
    for (final c in autoeqSearchCandidates(fr, frTarget, 1))
      if (c.freq <= _trebleStartFrom) c,
  ], math.max((maxFilters / 2).floor() - 1, 1));
  for (final i in iterations) {
    first = _optimize(fit, first, i);
  }

  final secondFr = autoeqApply(fr, first);
  final secondFit = _AutoEqFit(secondFr, frTarget);
  var second = widest(
    autoeqSearchCandidates(secondFr, frTarget, 0.5),
    maxFilters - first.length,
  );
  for (final i in iterations) {
    second = _optimize(secondFit, second, i);
  }

  var combined = [...first, ...second];
  for (final i in iterations) {
    combined = _optimize(fit, combined, i);
  }
  return autoeqStrip(combined);
}

// ---------------------------------------------------------------------------
// ISO 226:2003 equal-loudness normalization (port of CrinGraph's graphtool.js
// find_offset()/init_normalize()). The optimizer only has peaking filters, so
// both curves are shifted to the same loudness first; see the Python original.
// ---------------------------------------------------------------------------

const autoeqNormalizePhon = 60.0;

const _iso226F = <double>[
  20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, //
  200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
  2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500,
];

const _iso226AF = <double>[
  0.532, 0.506, 0.48, 0.455, 0.432, 0.409, 0.387, 0.367, 0.349, 0.33, //
  0.315, 0.301, 0.288, 0.276, 0.267, 0.259, 0.253, 0.25, 0.246, 0.244,
  0.243, 0.243, 0.243, 0.242, 0.242, 0.245, 0.254, 0.271, 0.301,
];

const _iso226LU = <double>[
  -31.6, -27.2, -23, -19.1, -15.9, -13, -10.3, -8.1, -6.2, -4.5, //
  -3.1, -2, -1.1, -0.4, 0, 0.3, 0.5, 0, -2.7, -4.1,
  -1, 1.7, 2.5, 1.2, -2.1, -7.1, -11.2, -10.7, -3.1,
];

const _iso226TF = <double>[
  78.5, 68.7, 59.5, 51.1, 44, 37.5, 31.5, 26.5, 22.1, 17.9, //
  14.4, 11.4, 8.6, 6.2, 4.4, 3, 2.2, 2.4, 3.5, 1.7,
  -1.3, -4.2, -6, -5.4, -1.5, 6, 12.6, 13.9, 12.3,
];

// Diffuse-field correction curve, ~1/48 octave from 19.4806 Hz, as used by
// CrinGraph's init_normalize() (raw values, before the "-7" dB shift).
const _freeFieldRaw = <double>[
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0.0725,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.0896,
  0,
  0,
  0,
  0,
  0,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.0967,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0.0886,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.0656,
  0,
  0,
  0,
  0,
  0,
  0.024,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.045,
  0,
  0,
  0,
  0,
  0,
  0,
  0.029,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1,
  0.1524,
  0.2,
  0.2,
  0.2386,
  0.3395,
  0.4,
  0.437,
  0.5,
  0.5287,
  0.6225,
  0.7,
  0.7063,
  0.7962,
  0.8,
  0.8941,
  0.9,
  0.9863,
  1,
  1.0729,
  1.1,
  1.1544,
  1.2,
  1.2504,
  1.3,
  1.3,
  1.3,
  1.3,
  1.3163,
  1.4,
  1.4,
  1.4,
  1.4,
  1.4017,
  1.4846,
  1.5,
  1.5,
  1.5748,
  1.6,
  1.6,
  1.653,
  1.7,
  1.7,
  1.7487,
  1.8,
  1.8341,
  1.9,
  1.9,
  1.9229,
  2,
  2,
  2,
  2.1,
  2.1,
  2.1897,
  2.2,
  2.2,
  2.2674,
  2.3,
  2.3,
  2.3567,
  2.4,
  2.4,
  2.4446,
  2.5,
  2.5262,
  2.6,
  2.6234,
  2.7149,
  2.8,
  2.8038,
  2.9011,
  2.9969,
  3.0913,
  3.1845,
  3.2762,
  3.3757,
  3.4649,
  3.5617,
  3.657,
  3.751,
  3.8,
  3.8432,
  3.9332,
  4,
  4,
  4,
  4.0121,
  4.1,
  4.1,
  4.1,
  4.0079,
  4,
  4,
  4,
  4,
  3.9334,
  3.9,
  3.9,
  3.9,
  3.8541,
  3.8,
  3.8,
  3.768,
  3.7,
  3.6761,
  3.6,
  3.6,
  3.5927,
  3.5,
  3.5,
  3.5,
  3.5,
  3.5,
  3.5761,
  3.6,
  3.6,
  3.6604,
  3.7,
  3.7514,
  3.8,
  3.8,
  3.8349,
  3.9,
  3.9218,
  4.0199,
  4.1123,
  4.2076,
  4.3016,
  4.3985,
  4.6816,
  5.0515,
  5.4222,
  5.8036,
  6.1097,
  6.4656,
  6.8461,
  7.3316,
  7.9083,
  8.4305,
  8.9369,
  9.5105,
  10.0759,
  10.6024,
  11.0027,
  11.4847,
  12.0482,
  12.5152,
  12.8994,
  13.2776,
  13.7381,
  14.1303,
  14.5168,
  14.8858,
  15.273,
  15.6547,
  15.9731,
  16.2596,
  16.542,
  16.7857,
  17.0111,
  17.2325,
  17.3532,
  17.522,
  17.6,
  17.6,
  17.6,
  17.6,
  17.5044,
  17.41,
  17.3145,
  17.2205,
  17.1255,
  17.0318,
  16.9373,
  16.784,
  16.6459,
  16.4536,
  16.2578,
  16.1234,
  15.967,
  15.8736,
  15.7552,
  15.566,
  15.3879,
  15.2881,
  15.0958,
  14.9064,
  14.8099,
  14.6287,
  14.5201,
  14.3477,
  14.2307,
  14.0709,
  13.9399,
  13.7916,
  13.6514,
  13.5552,
  13.4604,
  13.367,
  13.2718,
  13.1766,
  13.0812,
  12.9743,
  12.7916,
  12.6975,
  12.602,
  12.5078,
  12.3247,
  12.0547,
  11.7686,
  11.4154,
  11.1009,
  10.9385,
  10.7344,
  10.3998,
  10.0163,
  9.6382,
  9.2957,
  8.9799,
  8.6248,
  8.3404,
  8.0424,
  7.674,
  7.3851,
  7.0061,
  6.5307,
  6.1484,
  5.7696,
  5.4662,
  5.1084,
  4.7302,
  4.3498,
  3.971,
  3.6455,
  3.4075,
  3.1343,
  2.7917,
  2.5376,
  2.3484,
  2.1585,
  1.9849,
  1.9107,
  2,
  2,
  2,
  2.0894,
  2.1844,
  2.2787,
  2.374,
  2.6057,
  2.8265,
  3.0161,
  3.2057,
  3.3954,
  3.5851,
  3.8122,
  4.0967,
  4.354,
  4.5651,
  4.8509,
  5.1459,
  5.5259,
  5.9041,
  6.1881,
  6.5643,
  6.8561,
  7.1418,
  7.4251,
  7.7093,
  8.0593,
  8.3192,
  8.4541,
  8.5493,
  8.6437,
  8.7,
  8.7336,
  8.8,
  8.8,
  8.8,
  8.8,
  8.7926,
  8.7,
  8.7,
  8.6079,
  8.5133,
  8.5,
  8.4237,
  8.1863,
  7.968,
  7.7786,
  7.4219,
  6.948,
  6.4299,
  5.8212,
  5.1563,
  4.4634,
  3.7042,
  2.8897,
  1.9005,
  1.2368,
  0.5651,
  -0.2856,
  -0.8593,
  -2.9,
];

double _pow10(double x) => math.pow(10, x).toDouble();

/// dB offset that brings [curve] to [targetPhon] loudness (Newton's method).
double iso226FindOffset(List<Point> curve, [double targetPhon = 0]) {
  final n = _iso226F.length;
  final par = <(double, double, double)>[];
  final ff = <double>[];
  var idx = 0;
  for (final (f, _) in curve) {
    if (idx < n && f >= _iso226F[idx]) idx++;
    final i0 = math.max(0, idx - 1);
    final i1 = math.min(idx, n - 1);
    double a, lu, tf;
    if (i0 == i1) {
      a = _iso226AF[i0];
      lu = _iso226LU[i0];
      tf = _iso226TF[i0];
    } else {
      final l0 = math.log(_iso226F[i0]), l1 = math.log(_iso226F[i1]);
      final frac = (math.log(f) - l0) / (l1 - l0);
      a = _iso226AF[i0] + frac * (_iso226AF[i1] - _iso226AF[i0]);
      lu = _iso226LU[i0] + frac * (_iso226LU[i1] - _iso226LU[i0]);
      tf = _iso226TF[i0] + frac * (_iso226TF[i1] - _iso226TF[i0]);
    }
    final m = a * (log10(4) - 10 + lu / 10);
    final k = (0.005076 / _pow10(m)) - _pow10(a * tf / 10);
    final c = _pow10(9.4 + 4 * m) / curve.length;
    par.add((a, k, c));
    final ffi = (0.5 + 48 * math.log(f / 19.4806) / math.ln2).floor();
    ff.add(_freeFieldRaw[ffi.clamp(0, 479)] - 7);
  }

  final l10 = math.log(10) / 10;
  double step(double offset) {
    var vTotal = 0.0, dTotal = 0.0;
    for (var i = 0; i < curve.length; i++) {
      final (a, k, c) = par[i];
      final v0 = math.exp(l10 * (curve[i].$2 + offset - ff[i]));
      var ds = l10 * v0;
      final v1 = k + math.pow(v0, a);
      ds *= a * math.pow(v0, a - 1);
      vTotal += c * math.pow(v1, 4);
      ds *= c * 4 * math.pow(v1, 3);
      dTotal += ds;
    }
    return (math.log(vTotal) - targetPhon * l10) * (vTotal / dTotal);
  }

  var x = 0.0;
  for (var i = 0; i < 100; i++) {
    // converges in a handful of steps; capped as a safety net
    final dx = step(x);
    x -= dx;
    if (dx.abs() <= 0.01) break;
  }
  return x;
}

/// Shift [curve] by its own ISO-226 offset to [autoeqNormalizePhon].
List<Point> autoeqLoudnessNormalize(List<Point> curve) {
  final offset = iso226FindOffset(curve, autoeqNormalizePhon);
  return [for (final (f, v) in curve) (f, v + offset)];
}

class AutoEqResult {
  final List<Band> filters;
  final double preamp;
  const AutoEqResult(this.filters, this.preamp);
}

/// Full AutoEQ pipeline: filters and preamp that bring [measurement] towards
/// [target] (null = flat). Both inputs are (freq, dB) point lists at any
/// resolution. CPU-heavy: run it off the UI isolate.
AutoEqResult autoeqCompute(
  List<Point> measurement,
  List<Point>? target,
  int maxFilters,
) {
  final freqs = autoeqRawFrequencies();
  final fr = autoeqLoudnessNormalize(autoeqInterp(freqs, measurement));
  final frTarget = autoeqLoudnessNormalize(
    target == null
        ? [for (final f in freqs) (f, 0.0)]
        : autoeqInterp(freqs, target),
  );

  final filters = autoeqRun(fr, frTarget, maxFilters);
  final preamp = autoeqCalcPreamp(fr, autoeqApply(fr, filters));
  return AutoEqResult([
    for (final f in filters)
      Band(
        type: f.type,
        freq: roundTo(f.freq, 1),
        gain: roundTo(f.gain, 2),
        q: roundTo(f.q, 3),
      ),
  ], preamp);
}
