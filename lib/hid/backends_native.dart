import 'dart:io';

import 'android_usb_hid.dart';
import 'hid.dart';
import 'linux_hidraw.dart';
import 'macos_hid.dart';
import 'windows_hid.dart';

HidBackend createBackend() {
  if (Platform.isAndroid) return AndroidUsbHid();
  if (Platform.isLinux) return LinuxHidraw();
  if (Platform.isWindows) return WindowsHid();
  if (Platform.isMacOS) return MacosHid();
  return UnsupportedHid();
}
