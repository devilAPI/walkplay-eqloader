/// Profiles kept in the app's library, and what was last pushed to which
/// device slot.
library;

import 'band.dart';

class SavedProfile {
  final String name;
  final double preamp;
  final List<Band> filters;
  final DateTime saved;

  SavedProfile({
    required this.name,
    required this.preamp,
    required List<Band> filters,
    required this.saved,
  }) : filters = [for (final f in filters) f.copy()];

  SavedProfile renamed(String newName) => SavedProfile(
    name: newName,
    preamp: preamp,
    filters: filters,
    saved: saved,
  );

  /// Whether this profile holds exactly the EQ [filters] + [preamp].
  ///
  /// [asStored]: compare what the device keeps instead: only bands that are
  /// on, at the device's precision (whole Hz, 1/256 dB and Q), so an EQ read
  /// back from the device still matches. The preamp is ignored there: the
  /// gain register holds whole dB and clamps at the hardware buffer.
  bool matches(double preamp, List<Band> filters, {bool asStored = false}) {
    var mine = this.filters;
    if (asStored) {
      mine = [
        for (final f in mine)
          if (!filterIsOff(f)) f,
      ];
      filters = [
        for (final f in filters)
          if (!filterIsOff(f)) f,
      ];
    }
    final (hz, fine, db) = asStored
        ? (1.0, 0.01, double.infinity)
        : (1e-6, 1e-6, 1e-6);
    if ((preamp - this.preamp).abs() > db || filters.length != mine.length) {
      return false;
    }
    for (var i = 0; i < filters.length; i++) {
      final a = filters[i], b = mine[i];
      if (a.type != b.type ||
          (a.freq - b.freq).abs() > hz ||
          (a.gain - b.gain).abs() > fine ||
          (a.q - b.q).abs() > fine) {
        return false;
      }
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'preamp': preamp,
    'saved': saved.toIso8601String(),
    'filters': [
      for (final f in filters)
        {'type': f.type, 'freq': f.freq, 'gain': f.gain, 'q': f.q},
    ],
  };

  /// Null for an entry that isn't a valid profile.
  static SavedProfile? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'], preamp = j['preamp'], filters = j['filters'];
    if (name is! String || preamp is! num || filters is! List) return null;
    final bands = <Band>[];
    for (final f in filters) {
      if (f is! Map) return null;
      final type = f['type'], freq = f['freq'], gain = f['gain'], q = f['q'];
      if (type is! String || freq is! num || gain is! num || q is! num) {
        return null;
      }
      bands.add(
        Band(
          type: filterTypes.contains(type) ? type : 'PK',
          freq: freq.toDouble(),
          gain: gain.toDouble(),
          q: q.toDouble(),
        ),
      );
    }
    return SavedProfile(
      name: name,
      preamp: preamp.toDouble(),
      filters: bands,
      saved: DateTime.tryParse('${j['saved']}') ?? DateTime.now(),
    );
  }
}

/// What was pushed to one device slot: a library profile's name, or null for
/// an EQ that wasn't saved in the library.
class SlotRecord {
  final String? profile;
  final DateTime at;
  const SlotRecord(this.profile, this.at);

  Map<String, Object?> toJson() => {
    'profile': profile,
    'at': at.toIso8601String(),
  };

  static SlotRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    final profile = j['profile'];
    if (at == null || (profile != null && profile is! String)) return null;
    return SlotRecord(profile as String?, at);
  }
}
