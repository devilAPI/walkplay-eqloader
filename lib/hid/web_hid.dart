import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'hid.dart';

/// HID through the browser's WebHID API (Chrome, Edge, Opera on desktop).
///
/// Pages only see devices the user granted them via [requestAccess]; later
/// visits get those back from `getDevices()`. [HidDeviceInfo.path] is an
/// index into the last enumeration.
class WebHid extends HidBackend {
  var _devices = <_HidDevice>[];

  @override
  String? get unavailableReason => _hid == null
      ? 'This browser has no WebHID. Use Chrome, Edge or Opera on a desktop '
            'computer, or the desktop/Android app.'
      : null;

  @override
  bool get needsAccessRequest => true;

  @override
  Future<void> requestAccess(int vendorId) async {
    final hid = _hid;
    if (hid == null) throw StateError(unavailableReason!);
    final options =
        {
              'filters': [
                {'vendorId': vendorId},
              ],
            }.jsify()!
            as JSObject;
    await hid.requestDevice(options).toDart;
  }

  @override
  Future<List<HidDeviceInfo>> enumerate() async {
    final hid = _hid;
    if (hid == null) return [];
    _devices = (await hid.getDevices().toDart).toDart;
    return [
      for (var i = 0; i < _devices.length; i++)
        HidDeviceInfo(
          vendorId: _devices[i].vendorId,
          productId: _devices[i].productId,
          interfaceNumber: null,
          product: _devices[i].productName,
          manufacturer: '',
          path: '$i',
        ),
    ];
  }

  @override
  Future<HidConnection> open(HidDeviceInfo device) async {
    final i = int.parse(device.path);
    if (i >= _devices.length) {
      throw StateError('HID device not found; refresh the device list.');
    }
    final dev = _devices[i];
    if (!dev.opened) await dev.open().toDart;
    return _WebHidConnection(dev);
  }
}

class _WebHidConnection implements HidConnection {
  final _HidDevice _dev;
  final _reports = Queue<Uint8List>();
  Completer<void>? _waiter;
  late final JSFunction _listener = _onReport.toJS;

  /// Declared payload size (bytes, without the id) of each output report.
  late final Map<int, int> _outputSizes = _reportSizes(_dev.collections.toDart);

  _WebHidConnection(this._dev) {
    _dev.addEventListener('inputreport', _listener);
  }

  static Map<int, int> _reportSizes(List<_HidCollectionInfo> collections) {
    final sizes = <int, int>{};
    for (final c in collections) {
      for (final r in c.outputReports.toDart) {
        var bits = 0;
        for (final item in r.items.toDart) {
          bits += item.reportSize * item.reportCount;
        }
        sizes[r.reportId] = (bits + 7) ~/ 8;
      }
      sizes.addAll(_reportSizes(c.children.toDart));
    }
    return sizes;
  }

  void _onReport(web.Event event) {
    final e = event as _HidInputReportEvent;
    final data = e.data.toDart;
    // Report id first, like the other backends.
    _reports.add(
      Uint8List(data.lengthInBytes + 1)
        ..[0] = e.reportId
        ..setAll(1, Uint8List.sublistView(data)),
    );
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  @override
  Future<void> write(Uint8List data) async {
    // WebHID takes the report id separately from the payload, and the payload
    // must be exactly the size the device declares (the protocol pads its
    // packets past that, e.g. 64 bytes for a 63-byte report).
    final id = data[0];
    final size = _outputSizes[id] ?? data.length - 1;
    final payload = Uint8List(size)
      ..setRange(0, (data.length - 1).clamp(0, size), data, 1);
    try {
      await _dev.sendReport(id, payload.toJS).toDart;
    } catch (e) {
      throw StateError(
        'The browser refused to send HID report 0x${id.toRadixString(16)} '
        '($e). Details are in chrome://device-log.',
      );
    }
  }

  @override
  Future<Uint8List?> read(Duration timeout) async {
    if (_reports.isEmpty) {
      final waiter = _waiter ??= Completer<void>();
      await waiter.future.timeout(timeout, onTimeout: () {});
    }
    return _reports.isEmpty ? null : _reports.removeFirst();
  }

  @override
  Future<void> close() async {
    _dev.removeEventListener('inputreport', _listener);
    await _dev.close().toDart;
  }
}

// ---------------------------------------------------------------------------
// WebHID bindings (package:web doesn't include them)
// ---------------------------------------------------------------------------

@JS('navigator.hid')
external _Hid? get _hid;

extension type _Hid._(JSObject _) implements JSObject {
  external JSPromise<JSArray<_HidDevice>> getDevices();
  external JSPromise<JSArray<_HidDevice>> requestDevice(JSObject options);
}

extension type _HidDevice._(JSObject _) implements web.EventTarget {
  external bool get opened;
  external int get vendorId;
  external int get productId;
  external String get productName;
  external JSArray<_HidCollectionInfo> get collections;
  external JSPromise<JSAny?> open();
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> sendReport(int reportId, JSUint8Array data);
}

extension type _HidCollectionInfo._(JSObject _) implements JSObject {
  external JSArray<_HidReportInfo> get outputReports;
  external JSArray<_HidCollectionInfo> get children;
}

extension type _HidReportInfo._(JSObject _) implements JSObject {
  external int get reportId;
  external JSArray<_HidReportItem> get items;
}

extension type _HidReportItem._(JSObject _) implements JSObject {
  external int get reportSize;
  external int get reportCount;
}

extension type _HidInputReportEvent._(JSObject _) implements web.Event {
  external int get reportId;
  external JSDataView get data;
}
