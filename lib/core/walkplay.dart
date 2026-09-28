/// Device protocol (Walkplay HID), ported from logic/eqloader.py.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../hid/hid.dart';
import 'band.dart';
import 'dsp.dart';

const walkplayVendorId = 0x3302;

const reportId = 0x4B;
const _read = 0x80;
const _write = 0x01;
const _end = 0x00;
const reportLength = 64;

const cmdFlashEq = 0x01;
const cmdGlobalGain = 0x03;
const cmdPeqValues = 0x09;
const cmdTempWrite = 0x0A;
const cmdVersion = 0x0C;

const filterTypeToByte = {'LSQ': 1, 'PK': 2, 'HSQ': 3, 'LP': 4, 'HP': 5};
final byteToFilterType = {
  for (final e in filterTypeToByte.entries) e.value: e.key,
};

const defaultGlobalGainBuffer = -5.0;
const defaultMaxFilters = 8;

typedef Logger = void Function(String line);

List<int> _leBytes(num value, int length) {
  final v = pyRound(value.toDouble());
  return [for (var i = 0; i < length; i++) (v >> (8 * i)) & 0xFF];
}

/// The 20 coefficient bytes of one band, as the device expects them.
///
/// RBJ peaking biquad at [deviceSampleRate] (always a peaking design,
/// whatever the band's type, matching the vendor tool), as Q2.30 fixed point
/// words b0, b1, b2, -a1, -a2, little-endian.
List<int> computeIirFilter(double freq, double gain, double q) {
  final amp = math.sqrt(math.pow(10, gain / 20));
  final w0 = (freq * (2 * math.pi)) / deviceSampleRate;
  final alpha = math.sin(w0) / (2 * q);
  final a0 = alpha / amp + 1;
  final mid = (math.cos(w0) * -2) / a0;
  final b0 = (alpha * amp + 1) / a0;
  final b2 = (1 - alpha * amp) / a0;
  final a2 = (1 - alpha / amp) / a0;

  int q30(double x) => pyRound(x * (1 << 30));

  final words = [q30(b0), q30(mid), q30(b2), -q30(mid), -q30(a2)];
  return [
    for (final w in words)
      for (var i = 0; i < 4; i++) ((w & 0xFFFFFFFF) >> (8 * i)) & 0xFF,
  ];
}

/// PEQ_VALUES write packet for band [index] of [slot].
List<int> buildFilterPacket(int index, Band f, int slot) => [
  _write, cmdPeqValues, 0x18, 0x00, index, 0x00, 0x00, //
  ...computeIirFilter(f.freq, f.gain, f.q),
  ..._leBytes(f.freq, 2),
  ..._leBytes(pyRound(f.q * 256), 2),
  ..._leBytes(pyRound(f.gain * 256) & 0xFFFF, 2),
  filterTypeToByte[f.type] ?? 2, 0x00, slot, _end,
];

class PulledBand {
  final int index;
  final Band band;
  PulledBand(this.index, this.band);
}

PulledBand parseFilterPacket(List<int> packet) {
  final freq = (packet[27] | (packet[28] << 8)).toDouble();
  final q = pyRound((packet[29] | (packet[30] << 8)) / 256 * 100) / 100;
  var gainRaw = packet[31] | (packet[32] << 8);
  if (gainRaw > 32767) gainRaw -= 65536;
  final gain = pyRound(gainRaw / 256 * 100) / 100;
  final type = byteToFilterType[packet[33]] ?? 'PK';
  return PulledBand(
    packet[4],
    Band(
      type: type,
      freq: freq,
      gain: gain,
      q: q,
      disabled: isFilterDisabled(type, freq, gain, q),
    ),
  );
}

/// Gain register value (whole dB, <= 0) for [preamp].
///
/// The device already attenuates by the fixed [bufferDb] (-5 dB on the
/// Protocol Micro); the register only holds attenuation beyond that.
int preampToRegister(
  double preamp, [
  double bufferDb = defaultGlobalGainBuffer,
]) => pyRound(math.min(0, preamp - bufferDb));

/// Effective preamp the device applies for a gain register value.
double registerToPreamp(
  int register, [
  double bufferDb = defaultGlobalGainBuffer,
]) => register + bufferDb;

class PullResult {
  final int currentSlot;
  final int globalGain;
  final double preamp;
  final List<Band> filters;
  PullResult(this.currentSlot, this.globalGain, this.preamp, this.filters);
}

Future<void> _sleep(int ms) => Future.delayed(Duration(milliseconds: ms));

/// One open Walkplay device.
class WalkplayDevice {
  final HidConnection conn;
  final Logger log;

  WalkplayDevice(this.conn, this.log);

  Future<void> sendReport(List<int> packet) {
    final data = Uint8List(reportLength + 1);
    data[0] = reportId;
    for (var i = 0; i < math.min(packet.length, reportLength); i++) {
      data[i + 1] = packet[i] & 0xFF;
    }
    return conn.write(data);
  }

  Future<Uint8List?> _readReport([int timeoutMs = 200]) async {
    final data = await conn.read(Duration(milliseconds: timeoutMs));
    return data == null || data.isEmpty ? null : Uint8List.sublistView(data, 1);
  }

  Future<Uint8List> waitForResponse(
    int expectedCmd, [
    double timeout = 2.0,
  ]) async {
    final deadline = DateTime.now().add(
      Duration(milliseconds: (timeout * 1000).round()),
    );
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now()).inMilliseconds;
      final data = await _readReport(math.min(200, math.max(1, remaining)));
      if (data != null && data.length > 1 && data[1] == expectedCmd) {
        return data;
      }
    }
    throw TimeoutException(
      'Timeout waiting for response to cmd 0x${hex2(expectedCmd)}',
    );
  }

  Future<int> getCurrentSlot() async => (await getInfo()).slot;

  /// Firmware version and the active EQ slot (-1 when not reported).
  Future<({String version, int slot})> getInfo() async {
    await sendReport([_read, cmdVersion, _end]);
    var resp = await waitForResponse(cmdVersion);
    final version = String.fromCharCodes(
      resp.sublist(3, 6).where((b) => b < 0x80),
    );
    log("Firmware version: '$version'");

    await sendReport([_read, cmdPeqValues, _end]);
    resp = await waitForResponse(cmdPeqValues);
    final slot = resp.length > 35 ? resp[35] : -1;
    log('Current EQ slot: $slot');
    return (version: version, slot: slot);
  }

  Future<void> writeGlobalGain(int valueDb) =>
      sendReport([_write, cmdGlobalGain, 0x02, 0x00, valueDb & 0xFF]);

  Future<int> readGlobalGain() async {
    await sendReport([_read, cmdGlobalGain, 0x00]);
    final raw = (await waitForResponse(cmdGlobalGain, 1.0))[4];
    return raw > 127 ? raw - 256 : raw;
  }

  /// Write [filters] to [slot], set the gain register, and flash.
  Future<void> push(
    int slot,
    double globalGain,
    List<Band> filters, {
    double bufferDb = defaultGlobalGainBuffer,
    bool writeGain = true,
  }) async {
    for (var i = 0; i < filters.length; i++) {
      await sendReport(buildFilterPacket(i, filters[i], slot));
      await _sleep(20);
    }
    await _sleep(100);

    if (writeGain) {
      final gainToWrite = preampToRegister(globalGain, bufferDb);
      await writeGlobalGain(gainToWrite);
      log(
        'Set global gain register to $gainToWrite dB '
        '(preamp $globalGain dB, hardware buffer $bufferDb dB)',
      );
      await _sleep(50);
    }

    // Commit sequence as sent by the vendor tool (0x05/0x17 are undocumented).
    for (final (packet, pause) in [
      ([_write, 0x05, _end], 20),
      ([_write, 0x17, _end], 20),
      ([_write, cmdTempWrite, 0x04, 0x00, 0x00, 0xFF, 0xFF, _end], 50),
    ]) {
      await sendReport(packet);
      await _sleep(pause);
    }
    await sendReport([_write, cmdFlashEq, _end]);
    log(
      'Pushed ${filters.length} filter(s) to slot $slot and flashed to device.',
    );
  }

  /// Read [maxFilters] bands and the gain register.
  Future<PullResult> pull(
    int maxFilters, {
    int slotHint = -1,
    double timeout = 10.0,
    double bufferDb = defaultGlobalGainBuffer,
  }) async {
    for (var i = 0; i < maxFilters; i++) {
      await sendReport([_read, cmdPeqValues, 0x00, 0x00, i, _end]);
      await _sleep(50);
    }
    await _sleep(100);

    final filters = <int, Band>{};
    final deadline = DateTime.now().add(
      Duration(milliseconds: (timeout * 1000).round()),
    );
    while (filters.length < maxFilters && DateTime.now().isBefore(deadline)) {
      final data = await _readReport(200);
      if (data == null || data.length < 34 || data[1] != cmdPeqValues) continue;
      final parsed = parseFilterPacket(data);
      filters[parsed.index] = parsed.band;
    }
    if (filters.length < maxFilters) {
      log(
        'Warning: only received ${filters.length}/$maxFilters filters before timeout.',
      );
    }

    int globalGain;
    double preamp;
    try {
      globalGain = await readGlobalGain();
      preamp = registerToPreamp(globalGain, bufferDb);
      log(
        'Global gain register $globalGain dB -> preamp $preamp dB '
        '(hardware buffer $bufferDb dB)',
      );
    } on TimeoutException {
      log('Warning: could not read global gain; assuming preamp 0 dB.');
      globalGain = 0;
      preamp = 0;
    }

    final keys = filters.keys.toList()..sort();
    return PullResult(slotHint, globalGain, preamp, [
      for (final k in keys) filters[k]!,
    ]);
  }

  Future<void> enablePeq(bool enable, [int slotId = 0]) => sendReport([
    _write,
    cmdFlashEq,
    enable ? 1 : 0,
    enable ? slotId : 0x00,
    _end,
  ]);
}

String hex2(int v) => v.toRadixString(16).toUpperCase().padLeft(2, '0');
String hex4(int v) => v.toRadixString(16).toUpperCase().padLeft(4, '0');

class TimeoutException implements Exception {
  final String message;
  const TimeoutException(this.message);
  @override
  String toString() => message;
}
