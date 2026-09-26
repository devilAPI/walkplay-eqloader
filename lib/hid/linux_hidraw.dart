import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'hid.dart';

/// HID over the kernel's hidraw driver.
///
/// Device nodes need read/write access for the user, e.g. via the udev rule
/// in linux/99-walkplay-hid.rules.
class LinuxHidraw extends HidBackend {
  // A pending async read on a RandomAccessFile can't be cancelled or closed,
  // so each node keeps one reader for the app's lifetime and sessions share it.
  final _connections = <String, _HidrawConnection>{};

  @override
  Future<List<HidDeviceInfo>> enumerate() async {
    final dir = Directory('/sys/class/hidraw');
    if (!dir.existsSync()) return [];
    final devices = <HidDeviceInfo>[];
    final nodes = dir.listSync().map((e) => e.path).toList()..sort();
    for (final node in nodes) {
      final info = _readInfo(node);
      if (info != null) devices.add(info);
    }
    return devices;
  }

  HidDeviceInfo? _readInfo(String sysNode) {
    try {
      final uevent = File('$sysNode/device/uevent').readAsLinesSync();
      String? value(String key) => uevent
          .where((l) => l.startsWith('$key='))
          .map((l) => l.substring(key.length + 1))
          .firstOrNull;

      // HID_ID=0003:00003302:000012C0 (bus:vendor:product)
      final id = value('HID_ID')?.split(':');
      if (id == null || id.length != 3) return null;
      final phys = value('HID_PHYS') ?? '';
      final iface = RegExp(r'input(\d+)$').firstMatch(phys)?.group(1);

      var manufacturer = '';
      try {
        // .../<usb device>/<interface>/<hid device>
        final usbDevice = Directory('$sysNode/device')
            .resolveSymbolicLinksSync();
        manufacturer = File(
          '${Directory(usbDevice).parent.parent.path}/manufacturer',
        ).readAsStringSync().trim();
      } catch (_) {}

      return HidDeviceInfo(
        vendorId: int.parse(id[1], radix: 16),
        productId: int.parse(id[2], radix: 16),
        interfaceNumber: iface == null ? null : int.parse(iface),
        product: value('HID_NAME') ?? '',
        manufacturer: manufacturer,
        path: '/dev/${sysNode.split('/').last}',
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<HidConnection> open(HidDeviceInfo device) async {
    final existing = _connections[device.path];
    if (existing != null && existing.alive) {
      existing.discardPending();
      return existing;
    }
    try {
      final reader = await File(device.path).open(mode: FileMode.read);
      final writer = await File(device.path)
          .open(mode: FileMode.writeOnlyAppend);
      final conn = _HidrawConnection(reader, writer);
      _connections[device.path] = conn;
      return conn;
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 13) {
        throw FileSystemException(
          'Permission denied. Install the udev rule from '
          'linux/99-walkplay-hid.rules, then replug the device',
          device.path,
        );
      }
      rethrow;
    }
  }
}

class _HidrawConnection implements HidConnection {
  final RandomAccessFile _reader;
  final RandomAccessFile _writer;
  final _reports = Queue<Uint8List>();
  Completer<void>? _waiter;
  Object? _error;

  _HidrawConnection(this._reader, this._writer) {
    _readLoop();
  }

  bool get alive => _error == null;

  Future<void> _readLoop() async {
    try {
      while (true) {
        // hidraw returns exactly one report per read().
        final data = await _reader.read(4096);
        if (data.isEmpty) throw const FileSystemException('Device closed');
        _reports.add(data);
        _wake();
      }
    } catch (e) {
      _error = e;
      _wake();
    }
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// Drop reports left over from an earlier session.
  void discardPending() => _reports.clear();

  @override
  Future<void> write(Uint8List data) async {
    if (_error != null) throw StateError('HID device is gone: $_error');
    await _writer.writeFrom(data);
  }

  @override
  Future<Uint8List?> read(Duration timeout) async {
    if (_reports.isEmpty) {
      if (_error != null) throw StateError('HID device is gone: $_error');
      final waiter = _waiter ??= Completer<void>();
      await waiter.future.timeout(timeout, onTimeout: () {});
    }
    return _reports.isEmpty ? null : _reports.removeFirst();
  }

  @override
  Future<void> close() async {
    // Kept open for reuse; see LinuxHidraw._connections.
  }
}
