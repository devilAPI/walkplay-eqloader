import 'dart:typed_data';

import 'package:eqloader/core/band.dart';
import 'package:eqloader/core/saved_profile.dart';
import 'package:eqloader/core/walkplay.dart';
import 'package:eqloader/hid/hid.dart';
import 'package:eqloader/state/device_controller.dart';
import 'package:eqloader/state/eq_model.dart';
import 'package:eqloader/state/profile_library.dart';
import 'package:eqloader/state/settings.dart';
import 'package:eqloader/state/store.dart';
import 'package:eqloader/ui/eq_graph.dart';
import 'package:eqloader/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';

SavedProfile profile(String name, {double preamp = -3, double gain = 4}) =>
    SavedProfile(
      name: name,
      preamp: preamp,
      filters: [
        Band(type: 'LSQ', freq: 105, gain: gain, q: 0.7),
        Band(type: 'PK', freq: 3150.5, gain: -2.3, q: 1.41),
        // A 0 dB band: kept by the library, dropped by the device.
        Band(type: 'PK', freq: 1000, gain: 0, q: 1),
      ],
      saved: DateTime.utc(2026, 9, 28, 12),
    );

void main() {
  group('ProfileLibrary', () {
    test('persists profiles and slot records through the store', () {
      final store = MemoryStore();
      ProfileLibrary(store)
        ..save(profile('Zeta'))
        ..save(profile('alpha'))
        ..recordSlot('3302:4B11', 2, 'alpha', at: DateTime.utc(2026, 9, 28));

      final reloaded = ProfileLibrary(store);
      expect([for (final p in reloaded.profiles) p.name], ['alpha', 'Zeta']);
      expect(reloaded.profiles.first.filters.length, 3);
      expect(reloaded.profiles.first.filters[1].freq, 3150.5);
      final slots = reloaded.slotsOf('3302:4B11');
      expect(slots.single.$1, 2);
      expect(slots.single.$2.profile, 'alpha');
    });

    test('same name replaces, case-insensitively', () {
      final lib = ProfileLibrary(MemoryStore())
        ..save(profile('Harman'))
        ..save(profile('HARMAN', gain: 6));
      expect(lib.profiles.single.name, 'HARMAN');
      expect(lib.profiles.single.filters.first.gain, 6);
    });

    test('rename carries the slot records along', () {
      final lib = ProfileLibrary(MemoryStore())..save(profile('old'));
      lib.recordSlot('dev', 0, 'old');
      lib.recordSlot('dev', 1, null);
      lib.rename(lib.profiles.single, 'new');
      expect(lib.byName('new'), isNotNull);
      expect(lib.slotsOf('dev').map((s) => s.$2.profile), ['new', null]);
    });

    test('broken stored data is skipped, not fatal', () {
      final store = MemoryStore()
        ..setString('library.profiles', '[{"name": 3}, "x", null]')
        ..setString('library.slots', '{"dev": {"a": {}, "1": {"at": 5}}}');
      final lib = ProfileLibrary(store);
      expect(lib.profiles, isEmpty);
      expect(lib.slotsOf('dev'), isEmpty);
    });

    test('an EQ read back from the device matches its profile', () {
      final saved = profile('IEM');
      final lib = ProfileLibrary(MemoryStore())..save(saved);
      // What the device stores and returns for each band.
      final pulled = [
        for (final (i, f) in padForPush(saved.filters, 8).indexed)
          parseFilterPacket(buildFilterPacket(i, f, 0)).band,
      ];
      final m = EqModel()..setFilters(pulled, -5);
      expect(lib.matching(m.preampDb, m.filters), isNull);
      expect(lib.matching(m.preampDb, m.filters, asStored: true)?.name, 'IEM');

      m.applyField('gain', 5.0);
      expect(lib.matching(m.preampDb, m.filters, asStored: true), isNull);
    });
  });

  test('library profiles load back exactly, including 0 dB bands', () {
    final saved = profile('flat-ish');
    final m = EqModel()..setFilters(saved.filters, saved.preamp, clean: false);
    expect(saved.matches(m.preampDb, m.filters), isTrue);
    m.undo();
    expect(saved.matches(m.preampDb, m.filters), isFalse);
  });

  test('settings persist', () {
    final store = MemoryStore();
    Settings(store).update(
      showFlatReference: false,
      qAsBandwidth: true,
      maxFilters: 10,
      bufferDb: -3,
    );
    final s = Settings(store);
    expect(s.showFlatReference, isFalse);
    expect(s.qAsBandwidth, isTrue);
    expect(s.maxFilters, 10);
    expect(s.bufferDb, -3);
    expect(Settings(MemoryStore()).maxFilters, defaultMaxFilters);
  });

  test('the flat reference sits opposite the preamp', () {
    expect(flatReferenceGain(-6), 6);
    expect(flatReferenceGain(0), 0);
  });

  test('slot times read short', () {
    final now = DateTime(2026, 9, 28, 18);
    expect(formatWhen(DateTime(2026, 9, 28, 9, 5), now: now), '09:05');
    expect(formatWhen(DateTime(2026, 3, 1, 14, 3), now: now), '1 Mar 14:03');
    expect(formatWhen(DateTime(2025, 12, 24, 8), now: now), '24 Dec 2025');
  });

  test('the slot map follows the device, even one found by VID/PID', () async {
    const dongle = HidDeviceInfo(
      vendorId: walkplayVendorId,
      productId: 0xC20F,
      interfaceNumber: 3,
      product: 'Protocol Micro',
      manufacturer: 'Walkplay',
      path: 'fake',
    );
    final device = DeviceController(_FakeHid([dongle]), (_) {});
    expect(device.deviceKey, isNull);
    device.setText(pid: '0xc20f');
    expect(device.deviceKey, '3302:C20F');
    device.setText(pid: '');
    await device.withDevice((dev, info) async {});
    expect(device.lastUsed, same(dongle));
    expect(device.deviceKey, '3302:C20F');
  });
}

class _FakeHid extends HidBackend {
  final List<HidDeviceInfo> devices;
  _FakeHid(this.devices);

  @override
  Future<List<HidDeviceInfo>> enumerate() async => devices;

  @override
  Future<HidConnection> open(HidDeviceInfo device) async => _NoConnection();
}

class _NoConnection extends HidConnection {
  @override
  Future<void> write(Uint8List data) async {}

  @override
  Future<Uint8List?> read(Duration timeout) async => null;

  @override
  Future<void> close() async {}
}
