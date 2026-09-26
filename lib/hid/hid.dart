/// Platform-neutral HID access: Linux uses /dev/hidraw*, Android the USB
/// host API through a platform channel, Windows the HID class driver and
/// macOS IOKit (both through dart:ffi).
library;

import 'dart:io';
import 'dart:typed_data';

import 'android_usb_hid.dart';
import 'linux_hidraw.dart';
import 'macos_hid.dart';
import 'windows_hid.dart';

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

  static HidBackend create() {
    if (Platform.isAndroid) return AndroidUsbHid();
    if (Platform.isLinux) return LinuxHidraw();
    if (Platform.isWindows) return WindowsHid();
    if (Platform.isMacOS) return MacosHid();
    return _UnsupportedHid();
  }
}

class _UnsupportedHid extends HidBackend {
  @override
  String get unavailableReason =>
      'USB HID access is not implemented on this platform.';

  @override
  Future<List<HidDeviceInfo>> enumerate() async => [];

  @override
  Future<HidConnection> open(HidDeviceInfo device) =>
      throw UnsupportedError(unavailableReason);
}
