import 'package:flutter/foundation.dart';

import '../core/walkplay.dart';
import '../hid/hid.dart';
import 'eq_model.dart';

/// The dongle side: device list, which device to talk to, and the slot
/// fields. Errors are thrown to the caller, which reports them.
class DeviceController extends ChangeNotifier {
  final HidBackend backend;
  final void Function(String) log;

  DeviceController(this.backend, this.log);

  List<HidDeviceInfo> devices = [];
  HidDeviceInfo? selected;

  /// The device the last action ran on (it may have been found by VID/PID
  /// rather than selected).
  HidDeviceInfo? lastUsed;
  bool loaded = false;

  // Kept as typed text, parsed at use (hex VID/PID accepted).
  String vidText = '0x${hex4(walkplayVendorId)}';
  String pidText = '';
  String pushSlotText = '0';
  String enableSlotText = '0';

  int get pushSlot => parseIntText(pushSlotText, 0)!;
  int get enableSlot => parseIntText(enableSlotText, 0)!;

  /// Null when HID works here, else why it doesn't.
  String? get unavailableReason => backend.unavailableReason;

  /// "VID:PID" of the device the slot fields refer to: the selected one,
  /// else the typed VID/PID, else the last one used; null while unknown.
  String? get deviceKey {
    final d = selected;
    if (d != null) return keyOf(d);
    final pid = parseIntText(pidText);
    if (pid != null) {
      return '${hex4(parseIntText(vidText, walkplayVendorId)!)}:${hex4(pid)}';
    }
    final used = lastUsed;
    return used != null ? keyOf(used) : null;
  }

  static String keyOf(HidDeviceInfo d) =>
      '${hex4(d.vendorId)}:${hex4(d.productId)}';

  void setText({
    String? vid,
    String? pid,
    String? pushSlot,
    String? enableSlot,
  }) {
    vidText = vid ?? vidText;
    pidText = pid ?? pidText;
    pushSlotText = pushSlot ?? pushSlotText;
    enableSlotText = enableSlot ?? enableSlotText;
    notifyListeners();
  }

  Future<void> refresh() async {
    selected = null; // the old pick may be unplugged by now
    devices = [];
    loaded = false;
    notifyListeners();
    try {
      if (unavailableReason == null) {
        devices = (await backend.enumerate())
            .where((d) => d.vendorId == walkplayVendorId)
            .toList();
      }
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  /// Browsers: let the user pick the dongle, which grants access to it.
  Future<void> requestAccess() => backend.requestAccess(walkplayVendorId);

  void select(HidDeviceInfo d) {
    selected = d;
    vidText = '0x${hex4(d.vendorId)}';
    pidText = '0x${hex4(d.productId)}';
    notifyListeners();
  }

  /// Open the selected device (else by VID/PID, else the first with the
  /// VID), run [action] on it and close it again.
  Future<T> withDevice<T>(
    Future<T> Function(WalkplayDevice dev, HidDeviceInfo info) action,
  ) async {
    final reason = unavailableReason;
    if (reason != null) throw StateError(reason);
    final info =
        selected ??
        await _find(
          parseIntText(vidText, walkplayVendorId)!,
          parseIntText(pidText),
        );
    final conn = await backend.open(info);
    if (!identical(lastUsed, info)) {
      lastUsed = info;
      notifyListeners();
    }
    try {
      return await action(WalkplayDevice(conn, log), info);
    } finally {
      await conn.close();
    }
  }

  Future<HidDeviceInfo> _find(int vid, int? pid) async {
    final candidates = (await backend.enumerate())
        .where((d) => d.vendorId == vid && (pid == null || d.productId == pid))
        .toList();
    if (candidates.isEmpty) {
      throw StateError(
        'No HID device found with vendor id 0x${hex4(vid)}'
        '${pid != null ? ' and product id 0x${hex4(pid)}' : ''}. '
        '${backend.needsAccessRequest ? 'Click Connect Device to choose it' : 'Refresh the device list, or set VID/PID manually'}.',
      );
    }
    if (candidates.length > 1 && pid == null) {
      final names = candidates
          .map((d) => '0x${hex4(d.productId)} (${d.product})')
          .join(', ');
      log(
        'Warning: multiple Walkplay devices/interfaces found ($names). '
        'Using the first one. Select a specific device in the list, or set PID.',
      );
    }
    return candidates.first;
  }
}
