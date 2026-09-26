import 'package:flutter/services.dart';

import 'hid.dart';

/// HID over Android's USB host API (see MainActivity.kt). The native side
/// claims the HID interface and keeps polling its interrupt-IN endpoint into a
/// queue, as the kernel HID driver would on desktop.
class AndroidUsbHid extends HidBackend {
  static const _channel = MethodChannel('eqloader/usb_hid');

  @override
  Future<List<HidDeviceInfo>> enumerate() async {
    final list = await _channel.invokeListMethod<Map>('enumerate') ?? [];
    return [
      for (final d in list)
        HidDeviceInfo(
          vendorId: d['vendorId'] as int,
          productId: d['productId'] as int,
          interfaceNumber: d['interfaceNumber'] as int?,
          product: (d['product'] as String?) ?? '',
          manufacturer: (d['manufacturer'] as String?) ?? '',
          path: d['path'] as String,
        ),
    ];
  }

  @override
  Future<HidConnection> open(HidDeviceInfo device) async {
    final handle = await _channel.invokeMethod<int>('open', {
      'path': device.path,
    });
    return _AndroidConnection(handle!);
  }
}

class _AndroidConnection implements HidConnection {
  final int handle;
  _AndroidConnection(this.handle);

  @override
  Future<void> write(Uint8List data) => AndroidUsbHid._channel.invokeMethod(
    'write',
    {'handle': handle, 'data': data},
  );

  @override
  Future<Uint8List?> read(Duration timeout) =>
      AndroidUsbHid._channel.invokeMethod<Uint8List>('read', {
        'handle': handle,
        'timeoutMs': timeout.inMilliseconds,
      });

  @override
  Future<void> close() =>
      AndroidUsbHid._channel.invokeMethod('close', {'handle': handle});
}
