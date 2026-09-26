/// EQ bands ("filters") and band-list helpers.
///
/// Port of the band-list helpers of logic/eqloader.py. A band is a [Band] with
/// type one of [filterTypes]; a curve is a list of (freq, dB) records.
library;

const filterTypes = ['PK', 'LSQ', 'HSQ', 'LP', 'HP'];

class Band {
  String type;
  double freq;
  double gain;
  double q;

  /// Explicit OFF flag from a profile file or a device pull; null = infer.
  bool? disabled;

  Band({
    this.type = 'PK',
    required this.freq,
    required this.gain,
    required this.q,
    this.disabled,
  });

  Band copy() =>
      Band(type: type, freq: freq, gain: gain, q: q, disabled: disabled);

  @override
  String toString() => 'Band($type, $freq Hz, $gain dB, Q $q)';
}

/// How the device stores an unused band; also used to pad pushes.
Band inertFilter() => Band(type: 'PK', freq: 100, gain: 0, q: 1);

Band newBand() => Band(type: 'PK', freq: 1000, gain: 0, q: 1);

typedef Point = (double, double);

/// Return true when the device treats this band as OFF.
///
/// The device stores an off band as an inert flat filter (PK, Fc 100, Gain 0,
/// Q 1), so a peaking/shelf band with zero gain is audibly inert and must be
/// treated as off. LP/HP filters shape the signal regardless of gain, so only
/// a fully-zero slot counts.
bool isFilterDisabled(String type, double freq, double gain, double q) {
  if (type == 'PK' || type == 'LSQ' || type == 'HSQ') return gain == 0;
  return freq == 0 && q == 0 && gain == 0;
}

/// Explicit "disabled" flag if present (profiles, pulls), else inferred.
bool filterIsOff(Band f) =>
    f.disabled ?? isFilterDisabled(f.type, f.freq, f.gain, f.q);

/// Drop exact-duplicate bands, keeping first occurrence.
///
/// The device always stores a fixed number of slots (typically 8); pushing
/// fewer bands leaves it padding the tail by repeating the last band(s), so a
/// pulled profile can contain identical copies.
List<Band> dedupeFilters(List<Band> filters) {
  final seen = <String>{};
  final result = <Band>[];
  for (final f in filters) {
    final key =
        '${f.type}|${f.freq.toStringAsFixed(2)}|'
        '${f.gain.toStringAsFixed(2)}|${f.q.toStringAsFixed(3)}';
    if (seen.add(key)) result.add(f);
  }
  return result;
}

/// Editable bands from a loaded/pulled profile: OFF bands dropped, a zero
/// freq/Q replaced by a usable default and exact duplicates collapsed.
List<Band> activeFilters(List<Band> filters) => dedupeFilters([
  for (final f in filters)
    if (!filterIsOff(f))
      Band(
        type: f.type,
        freq: f.freq == 0 ? 1000 : f.freq,
        gain: f.gain,
        q: f.q == 0 ? 1 : f.q,
      ),
]);

/// Copy of [filters] padded with inert bands up to the device's slot count,
/// so the device doesn't backfill the unused tail slots with copies of the
/// last real band.
List<Band> padForPush(List<Band> filters, int maxFilters) => [
  for (final f in filters) f.copy(),
  for (var i = filters.length; i < maxFilters; i++) inertFilter(),
];

/// Python's round(): nearest integer, ties to even.
int pyRound(double x) {
  final f = x.floorToDouble();
  final diff = x - f;
  if (diff > 0.5) return f.toInt() + 1;
  if (diff < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

/// Python's round(x, n) for display/storage rounding.
double roundTo(double x, int decimals) =>
    double.parse(x.toStringAsFixed(decimals));

/// Stable sort (Dart's List.sort is not guaranteed stable; the AutoEQ port
/// relies on Python's stable sort order).
void stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}
