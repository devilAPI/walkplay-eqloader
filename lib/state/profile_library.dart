import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/band.dart';
import '../core/saved_profile.dart';
import 'store.dart';

/// Named EQ profiles stored in the app, plus which profile was pushed to
/// which slot of which device.
class ProfileLibrary extends ChangeNotifier {
  static const _profilesKey = 'library.profiles';
  static const _slotsKey = 'library.slots';

  final KeyValueStore _store;

  List<SavedProfile> _profiles = [];

  /// Bumped on every change, for cheap rebuild checks.
  int revision = 0;

  /// Device key ("VID:PID") -> slot -> record.
  final _slots = <String, Map<int, SlotRecord>>{};

  ProfileLibrary(this._store) {
    try {
      final list = jsonDecode(_store.getString(_profilesKey) ?? '[]');
      if (list is List) {
        _profiles = [for (final j in list) ?SavedProfile.fromJson(j)];
        _sort();
      }
    } catch (_) {}
    try {
      final devices = jsonDecode(_store.getString(_slotsKey) ?? '{}');
      if (devices is Map) {
        for (final MapEntry(key: device, value: slots) in devices.entries) {
          if (slots is! Map) continue;
          _slots['$device'] = {
            for (final MapEntry(:key, :value) in slots.entries)
              ?int.tryParse('$key'): ?SlotRecord.fromJson(value),
          };
        }
      }
    } catch (_) {}
  }

  /// Sorted by name.
  List<SavedProfile> get profiles => List.unmodifiable(_profiles);

  SavedProfile? byName(String name) {
    final key = name.trim().toLowerCase();
    for (final p in _profiles) {
      if (p.name.toLowerCase() == key) return p;
    }
    return null;
  }

  /// The profile holding this EQ, if any; see [SavedProfile.matches].
  SavedProfile? matching(
    double preamp,
    List<Band> filters, {
    bool asStored = false,
  }) {
    for (final p in _profiles) {
      if (p.matches(preamp, filters, asStored: asStored)) return p;
    }
    return null;
  }

  /// Add [profile], replacing one with the same name (case-insensitive).
  void save(SavedProfile profile) {
    _profiles.removeWhere(
      (p) => p.name.toLowerCase() == profile.name.toLowerCase(),
    );
    _profiles.add(profile);
    _changedProfiles();
  }

  /// Rename, keeping the slot records that point at the profile.
  void rename(SavedProfile profile, String newName) {
    final i = _profiles.indexWhere((p) => p.name == profile.name);
    if (i < 0) return;
    _profiles[i] = profile.renamed(newName);
    for (final slots in _slots.values) {
      for (final MapEntry(:key, :value) in slots.entries.toList()) {
        if (value.profile == profile.name) {
          slots[key] = SlotRecord(newName, value.at);
        }
      }
    }
    _changedProfiles();
    _saveSlots();
  }

  void delete(SavedProfile profile) {
    _profiles.removeWhere((p) => p.name == profile.name);
    _changedProfiles();
  }

  void _sort() => _profiles.sort(
    (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );

  void _changedProfiles() {
    revision++;
    _sort();
    _store.setString(
      _profilesKey,
      jsonEncode([for (final p in _profiles) p.toJson()]),
    );
    notifyListeners();
  }

  // ---- slot map ----------------------------------------------------------

  /// Records for [deviceKey], by slot.
  List<(int, SlotRecord)> slotsOf(String deviceKey) {
    final slots = _slots[deviceKey] ?? const {};
    return [for (final s in slots.keys.toList()..sort()) (s, slots[s]!)];
  }

  void recordSlot(String deviceKey, int slot, String? profile, {DateTime? at}) {
    (_slots[deviceKey] ??= {})[slot] = SlotRecord(
      profile,
      at ?? DateTime.now(),
    );
    revision++;
    _saveSlots();
    notifyListeners();
  }

  void _saveSlots() => _store.setString(
    _slotsKey,
    jsonEncode({
      for (final MapEntry(key: device, value: slots) in _slots.entries)
        device: {
          for (final MapEntry(:key, :value) in slots.entries)
            '$key': value.toJson(),
        },
    }),
  );
}
