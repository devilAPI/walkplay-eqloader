import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'hid.dart';
import 'isolate_reader.dart';

/// HID through IOKit's IOHIDManager / IOHIDDevice.
///
/// [HidDeviceInfo.path] is the device's IORegistry entry id.
class MacosHid extends HidBackend {
  @override
  Future<List<HidDeviceInfo>> enumerate() async {
    final devices = <HidDeviceInfo>[];
    final manager = _io.managerCreate(nullptr, 0);
    if (manager == nullptr) return devices;
    try {
      _io.managerSetDeviceMatching(manager, nullptr); // every HID device
      final set = _io.managerCopyDevices(manager);
      if (set == nullptr) return devices;
      try {
        final count = _cf.setGetCount(set);
        final refs = calloc<Pointer<Void>>(count);
        try {
          _cf.setGetValues(set, refs);
          for (var i = 0; i < count; i++) {
            final info = _describe(refs[i]);
            if (info != null) devices.add(info);
          }
        } finally {
          calloc.free(refs);
        }
      } finally {
        _cf.release(set);
      }
    } finally {
      _cf.release(manager);
    }
    return devices;
  }

  HidDeviceInfo? _describe(Pointer<Void> device) {
    final vid = _intProperty(device, 'VendorID');
    final pid = _intProperty(device, 'ProductID');
    final service = _io.deviceGetService(device);
    if (vid == null || pid == null || service == 0) return null;
    final id = calloc<Uint64>();
    try {
      if (_io.registryEntryGetId(service, id) != 0) return null;
      return HidDeviceInfo(
        vendorId: vid,
        productId: pid,
        interfaceNumber: null,
        product: _stringProperty(device, 'Product'),
        manufacturer: _stringProperty(device, 'Manufacturer'),
        path: '${id.value}',
      );
    } finally {
      calloc.free(id);
    }
  }

  @override
  Future<HidConnection> open(HidDeviceInfo device) async {
    final service = _io.getMatchingService(
      0, // kIOMainPortDefault
      _io.registryEntryIdMatching(int.parse(device.path)),
    );
    if (service == 0) {
      throw StateError('HID device not found; was it unplugged?');
    }
    final dev = _io.deviceCreate(nullptr, service);
    _io.objectRelease(service);
    if (dev == nullptr) throw StateError('Could not access the HID device');
    final result = _io.deviceOpen(dev, 0);
    if (result != 0) {
      _cf.release(dev);
      throw StateError(
        'Could not open the HID device '
        '(IOReturn 0x${result.toUnsigned(32).toRadixString(16)})',
      );
    }
    final inLen = math.max(_intProperty(dev, 'MaxInputReportSize') ?? 0, 64);
    final conn = _MacosConnection(dev);
    await conn.startReader(_readLoop, (dev.address, inLen));
    return conn;
  }
}

class _MacosConnection extends IsolateReadConnection {
  final Pointer<Void> _dev;
  _MacosConnection(this._dev);

  @override
  Future<void> write(Uint8List data) async {
    checkAlive();
    final buf = calloc<Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      // Numbered reports are passed with their report id as the first byte.
      final r = _io.deviceSetReport(
        _dev,
        _reportTypeOutput,
        data[0],
        buf,
        data.length,
      );
      if (r != 0) {
        throw StateError(
          'Writing to the HID device failed '
          '(IOReturn 0x${r.toUnsigned(32).toRadixString(16)})',
        );
      }
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Future<void> close() async {
    await stopReader();
    _io.deviceClose(_dev, 0);
    _cf.release(_dev);
  }
}

typedef _ReportCallback = Void Function(
  Pointer<Void> context,
  Int32 result,
  Pointer<Void> sender,
  Int32 type,
  Uint32 reportId,
  Pointer<Uint8> report,
  IntPtr length,
);

/// Reader isolate: schedules the device on this thread's run loop and runs
/// it in short slices; input reports arrive through a synchronous callback.
///
/// Never awaits, so the isolate stays on one OS thread (the run loop's).
void _readLoop(ReaderArgs<(int, int)> msg) {
  final (port, stopAddr, (devAddr, len)) = msg;
  final stop = Pointer<Int32>.fromAddress(stopAddr);
  final dev = Pointer<Void>.fromAddress(devAddr);
  final buf = calloc<Uint8>(len);
  final callback = NativeCallable<_ReportCallback>.isolateLocal((
    Pointer<Void> context,
    int result,
    Pointer<Void> sender,
    int type,
    int reportId,
    Pointer<Uint8> report,
    int length,
  ) {
    // The report already starts with its report id.
    if (result == 0 && length > 0) {
      sendReport(port, Uint8List.fromList(report.asTypedList(length)));
    }
  });
  final loop = _cf.runLoopGetCurrent();
  final mode = _cf.defaultMode;
  _io.deviceRegisterInputReportCallback(
    dev,
    buf,
    len,
    callback.nativeFunction,
    nullptr,
  );
  _io.deviceSchedule(dev, loop, mode);
  try {
    while (stop.value == 0) {
      _cf.runLoopRunInMode(mode, 0.1, 0);
    }
  } finally {
    _io.deviceUnschedule(dev, loop, mode);
    _io.deviceRegisterInputReportCallback(dev, buf, len, nullptr, nullptr);
    callback.close();
    calloc.free(buf);
  }
}

// ---------------------------------------------------------------------------
// Property helpers
// ---------------------------------------------------------------------------

Pointer<Void> _property(Pointer<Void> device, String key) {
  final k = _cfString(key);
  try {
    return _io.deviceGetProperty(device, k);
  } finally {
    _cf.release(k);
  }
}

int? _intProperty(Pointer<Void> device, String key) {
  final v = _property(device, key);
  if (v == nullptr || _cf.getTypeId(v) != _cf.numberTypeId()) return null;
  final out = calloc<Int64>();
  try {
    return _cf.numberGetValue(v, _cfNumberSInt64Type, out.cast()) != 0
        ? out.value
        : null;
  } finally {
    calloc.free(out);
  }
}

String _stringProperty(Pointer<Void> device, String key) {
  final v = _property(device, key);
  if (v == nullptr || _cf.getTypeId(v) != _cf.stringTypeId()) return '';
  const size = 512;
  final buf = calloc<Uint8>(size);
  try {
    return _cf.stringGetCString(v, buf.cast(), size, _utf8) != 0
        ? buf.cast<Utf8>().toDartString()
        : '';
  } finally {
    calloc.free(buf);
  }
}

Pointer<Void> _cfString(String s) {
  final c = s.toNativeUtf8();
  try {
    return _cf.stringCreateWithCString(nullptr, c, _utf8);
  } finally {
    calloc.free(c);
  }
}

const _utf8 = 0x08000100; // kCFStringEncodingUTF8
const _cfNumberSInt64Type = 4;
const _reportTypeOutput = 1; // kIOHIDReportTypeOutput

// ---------------------------------------------------------------------------
// Bindings (resolved lazily, per isolate, only on macOS)
// ---------------------------------------------------------------------------

final _cf = _CoreFoundation(
  DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
  ),
);
final _io = _IOKit(
  DynamicLibrary.open('/System/Library/Frameworks/IOKit.framework/IOKit'),
);

typedef _P = Pointer<Void>;

class _CoreFoundation {
  _CoreFoundation(DynamicLibrary l)
    : release = l.lookupFunction<Void Function(_P), void Function(_P)>(
        'CFRelease',
      ),
      setGetCount = l.lookupFunction<IntPtr Function(_P), int Function(_P)>(
        'CFSetGetCount',
      ),
      setGetValues = l
          .lookupFunction<
            Void Function(_P, Pointer<_P>),
            void Function(_P, Pointer<_P>)
          >('CFSetGetValues'),
      getTypeId = l.lookupFunction<UintPtr Function(_P), int Function(_P)>(
        'CFGetTypeID',
      ),
      numberTypeId = l.lookupFunction<UintPtr Function(), int Function()>(
        'CFNumberGetTypeID',
      ),
      stringTypeId = l.lookupFunction<UintPtr Function(), int Function()>(
        'CFStringGetTypeID',
      ),
      numberGetValue = l
          .lookupFunction<
            Uint8 Function(_P, IntPtr, _P),
            int Function(_P, int, _P)
          >('CFNumberGetValue'),
      stringGetCString = l
          .lookupFunction<
            Uint8 Function(_P, Pointer<Char>, IntPtr, Uint32),
            int Function(_P, Pointer<Char>, int, int)
          >('CFStringGetCString'),
      stringCreateWithCString = l
          .lookupFunction<
            _P Function(_P, Pointer<Utf8>, Uint32),
            _P Function(_P, Pointer<Utf8>, int)
          >('CFStringCreateWithCString'),
      runLoopGetCurrent = l.lookupFunction<_P Function(), _P Function()>(
        'CFRunLoopGetCurrent',
      ),
      runLoopRunInMode = l
          .lookupFunction<
            Int32 Function(_P, Double, Uint8),
            int Function(_P, double, int)
          >('CFRunLoopRunInMode'),
      defaultMode = l.lookup<_P>('kCFRunLoopDefaultMode').value;

  final void Function(_P) release;
  final int Function(_P) setGetCount;
  final void Function(_P, Pointer<_P>) setGetValues;
  final int Function(_P) getTypeId;
  final int Function() numberTypeId;
  final int Function() stringTypeId;
  final int Function(_P, int, _P) numberGetValue;
  final int Function(_P, Pointer<Char>, int, int) stringGetCString;
  final _P Function(_P, Pointer<Utf8>, int) stringCreateWithCString;
  final _P Function() runLoopGetCurrent;
  final int Function(_P, double, int) runLoopRunInMode;
  final _P defaultMode;
}

class _IOKit {
  _IOKit(DynamicLibrary l)
    : managerCreate = l
          .lookupFunction<_P Function(_P, Uint32), _P Function(_P, int)>(
            'IOHIDManagerCreate',
          ),
      managerSetDeviceMatching = l
          .lookupFunction<Void Function(_P, _P), void Function(_P, _P)>(
            'IOHIDManagerSetDeviceMatching',
          ),
      managerCopyDevices = l.lookupFunction<_P Function(_P), _P Function(_P)>(
        'IOHIDManagerCopyDevices',
      ),
      deviceGetProperty = l
          .lookupFunction<_P Function(_P, _P), _P Function(_P, _P)>(
            'IOHIDDeviceGetProperty',
          ),
      deviceGetService = l
          .lookupFunction<Uint32 Function(_P), int Function(_P)>(
            'IOHIDDeviceGetService',
          ),
      registryEntryGetId = l
          .lookupFunction<
            Int32 Function(Uint32, Pointer<Uint64>),
            int Function(int, Pointer<Uint64>)
          >('IORegistryEntryGetRegistryEntryID'),
      registryEntryIdMatching = l
          .lookupFunction<_P Function(Uint64), _P Function(int)>(
            'IORegistryEntryIDMatching',
          ),
      getMatchingService = l
          .lookupFunction<Uint32 Function(Uint32, _P), int Function(int, _P)>(
            'IOServiceGetMatchingService',
          ),
      objectRelease = l
          .lookupFunction<Int32 Function(Uint32), int Function(int)>(
            'IOObjectRelease',
          ),
      deviceCreate = l
          .lookupFunction<_P Function(_P, Uint32), _P Function(_P, int)>(
            'IOHIDDeviceCreate',
          ),
      deviceOpen = l
          .lookupFunction<Int32 Function(_P, Uint32), int Function(_P, int)>(
            'IOHIDDeviceOpen',
          ),
      deviceClose = l
          .lookupFunction<Int32 Function(_P, Uint32), int Function(_P, int)>(
            'IOHIDDeviceClose',
          ),
      deviceSetReport = l
          .lookupFunction<
            Int32 Function(_P, Int32, IntPtr, Pointer<Uint8>, IntPtr),
            int Function(_P, int, int, Pointer<Uint8>, int)
          >('IOHIDDeviceSetReport'),
      deviceRegisterInputReportCallback = l
          .lookupFunction<
            Void Function(
              _P,
              Pointer<Uint8>,
              IntPtr,
              Pointer<NativeFunction<_ReportCallback>>,
              _P,
            ),
            void Function(
              _P,
              Pointer<Uint8>,
              int,
              Pointer<NativeFunction<_ReportCallback>>,
              _P,
            )
          >('IOHIDDeviceRegisterInputReportCallback'),
      deviceSchedule = l
          .lookupFunction<Void Function(_P, _P, _P), void Function(_P, _P, _P)>(
            'IOHIDDeviceScheduleWithRunLoop',
          ),
      deviceUnschedule = l
          .lookupFunction<Void Function(_P, _P, _P), void Function(_P, _P, _P)>(
            'IOHIDDeviceUnscheduleFromRunLoop',
          );

  final _P Function(_P, int) managerCreate;
  final void Function(_P, _P) managerSetDeviceMatching;
  final _P Function(_P) managerCopyDevices;
  final _P Function(_P, _P) deviceGetProperty;
  final int Function(_P) deviceGetService;
  final int Function(int, Pointer<Uint64>) registryEntryGetId;
  final _P Function(int) registryEntryIdMatching;
  final int Function(int, _P) getMatchingService;
  final int Function(int) objectRelease;
  final _P Function(_P, int) deviceCreate;
  final int Function(_P, int) deviceOpen;
  final int Function(_P, int) deviceClose;
  final int Function(_P, int, int, Pointer<Uint8>, int) deviceSetReport;
  final void Function(
    _P,
    Pointer<Uint8>,
    int,
    Pointer<NativeFunction<_ReportCallback>>,
    _P,
  )
  deviceRegisterInputReportCallback;
  final void Function(_P, _P, _P) deviceSchedule;
  final void Function(_P, _P, _P) deviceUnschedule;
}
