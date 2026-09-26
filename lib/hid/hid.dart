/// Platform-neutral HID access: Linux uses /dev/hidraw*, Android the USB
/// host API through a platform channel, Windows the HID class driver and
/// macOS IOKit (both through dart:ffi), browsers WebHID.
library;

import 'dart:typed_data';

// dart:ffi doesn't exist on the web, so the backends are picked per target.
import 'backends_native.dart'
    if (dart.library.js_interop) 'backends_web.dart'
    as backends;

class HidDeviceInfo {
  final int vendorId;
  final int productId;
  final int? interfaceNumber;
  final String product;
  final String manufacturer;

  /// Backend-specific handle used to open the device.
  final String path;

  const HidDeviceInfo({
    required this.vendorId,
    required this.productId,
    required this.interfaceNumber,
    required this.product,
    required this.manufacturer,
    required this.path,
  });
}

abstract class HidConnection {
  /// Send one output report; [data] starts with the report id.
  Future<void> write(Uint8List data);

  /// Next input report (report id first), or null after [timeout].
  Future<Uint8List?> read(Duration timeout);

  Future<void> close();
}

abstract class HidBackend {
  /// Null when HID works on this platform, else why it doesn't.
  String? get unavailableReason => null;

  Future<List<HidDeviceInfo>> enumerate();

  Future<HidConnection> open(HidDeviceInfo device);

  /// True when devices only show up after [requestAccess] (browsers).
  bool get needsAccessRequest => false;

  /// Let the user grant access to a device with [vendorId]. Browsers only
  /// allow this from a user gesture, e.g. a button press.
  Future<void> requestAccess(int vendorId) async {}

  static HidBackend create() => backends.createBackend();
}

class UnsupportedHid extends HidBackend {
  @override
  String get unavailableReason =>
      'USB HID access is not implemented on this platform.';

  @override
  Future<List<HidDeviceInfo>> enumerate() async => [];

  @override
  Future<HidConnection> open(HidDeviceInfo device) =>
      throw UnsupportedError(unavailableReason);
}
