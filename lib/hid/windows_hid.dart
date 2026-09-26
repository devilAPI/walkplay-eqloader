import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'hid.dart';
import 'isolate_reader.dart';

/// HID through the Windows HID class driver (SetupAPI + hid.dll).
class WindowsHid extends HidBackend {
  @override
  Future<List<HidDeviceInfo>> enumerate() async {
    final devices = <HidDeviceInfo>[];
    final guid = calloc<Uint8>(16);
    final ifData = calloc<Uint8>(_spInterfaceDataSize);
    final required = calloc<Uint32>();
    try {
      _hid.getHidGuid(guid);
      final set = _setup.getClassDevs(
        guid,
        nullptr,
        nullptr,
        _digcfPresent | _digcfDeviceInterface,
      );
      if (_invalid(set)) return devices;
      try {
        ifData.cast<Uint32>().value = _spInterfaceDataSize;
        for (
          var i = 0;
          _setup.enumInterfaces(set, nullptr, guid, i, ifData) != 0;
          i++
        ) {
          _setup.interfaceDetail(set, ifData, nullptr, 0, required, nullptr);
          if (required.value < 8) continue;
          final detail = calloc<Uint8>(required.value);
          try {
            // cbSize of SP_DEVICE_INTERFACE_DETAIL_DATA_W on 64-bit Windows.
            detail.cast<Uint32>().value = 8;
            if (_setup.interfaceDetail(
                  set,
                  ifData,
                  detail,
                  required.value,
                  nullptr,
                  nullptr,
                ) ==
                0) {
              continue;
            }
            final path = (detail + 4).cast<Utf16>().toDartString();
            final info = _describe(path);
            if (info != null) devices.add(info);
          } finally {
            calloc.free(detail);
          }
        }
      } finally {
        _setup.destroyList(set);
      }
    } finally {
      calloc.free(guid);
      calloc.free(ifData);
      calloc.free(required);
    }
    return devices;
  }

  HidDeviceInfo? _describe(String path) {
    // Access 0: query only, works even for devices other apps hold open.
    final h = _createFile(path, 0, 0);
    if (_invalid(h)) return null;
    try {
      final attrs = calloc<Uint8>(12);
      try {
        attrs.cast<Uint32>().value = 12;
        if (_hid.getAttributes(h, attrs) == 0) return null;
        // A collection without output reports can't take commands.
        final (_, outLen) = _reportLengths(h);
        if (outLen == 0) return null;
        final iface = RegExp(
          r'&mi_([0-9a-f]{2})',
          caseSensitive: false,
        ).firstMatch(path)?.group(1);
        return HidDeviceInfo(
          vendorId: (attrs + 4).cast<Uint16>().value,
          productId: (attrs + 6).cast<Uint16>().value,
          interfaceNumber: iface == null ? null : int.parse(iface, radix: 16),
          product: _string(h, _hid.getProductString),
          manufacturer: _string(h, _hid.getManufacturerString),
          path: path,
        );
      } finally {
        calloc.free(attrs);
      }
    } finally {
      _kernel.closeHandle(h);
    }
  }

  @override
  Future<HidConnection> open(HidDeviceInfo device) async {
    // Separate handles: a blocking read on a synchronous handle would stall
    // writes on it, so reads use their own overlapped handle.
    final writer = _createFile(device.path, _genericRead | _genericWrite, 0);
    if (_invalid(writer)) {
      throw FileSystemException(
        'Could not open the HID device (in use by another app?)',
        device.path,
      );
    }
    final reader = _createFile(
      device.path,
      _genericRead | _genericWrite,
      _fileFlagOverlapped,
    );
    if (_invalid(reader)) {
      _kernel.closeHandle(writer);
      throw FileSystemException('Could not open the HID device', device.path);
    }
    final (inLen, outLen) = _reportLengths(writer);
    final conn = _WindowsConnection(writer, outLen);
    await conn.startReader(_readLoop, (reader.address, math.max(inLen, 1)));
    return conn;
  }
}

class _WindowsConnection extends IsolateReadConnection {
  final Pointer<Void> _handle;
  final int _outLen;
  _WindowsConnection(this._handle, this._outLen);

  @override
  Future<void> write(Uint8List data) async {
    checkAlive();
    // Windows wants exactly OutputReportByteLength bytes, report id first.
    final len = math.max(_outLen, data.length);
    final buf = calloc<Uint8>(len);
    final written = calloc<Uint32>();
    try {
      buf.asTypedList(len).setRange(0, data.length, data);
      if (_kernel.writeFile(_handle, buf.cast(), len, written, nullptr) == 0) {
        throw const FileSystemException('Writing to the HID device failed');
      }
    } finally {
      calloc.free(buf);
      calloc.free(written);
    }
  }

  @override
  Future<void> close() async {
    await stopReader();
    _kernel.closeHandle(_handle);
  }
}

/// Reader isolate: overlapped reads on the handle (which it owns and closes),
/// waiting in short slices so it notices the stop flag.
void _readLoop(ReaderArgs<(int, int)> msg) {
  final (port, stopAddr, (handleAddr, len)) = msg;
  final stop = Pointer<Int32>.fromAddress(stopAddr);
  final handle = Pointer<Void>.fromAddress(handleAddr);
  final buf = calloc<Uint8>(len);
  final ov = calloc<Uint8>(_overlappedSize);
  final got = calloc<Uint32>();
  final event = _kernel.createEvent(nullptr, 1, 0, nullptr);
  final status = ov.cast<IntPtr>(); // OVERLAPPED.Internal
  (ov + 24).cast<Pointer<Void>>().value = event; // OVERLAPPED.hEvent
  try {
    while (stop.value == 0) {
      _kernel.resetEvent(event);
      status.value = _notStarted;
      final ok = _kernel.readFile(handle, buf.cast(), len, nullptr, ov.cast());
      if (ok == 0 && status.value == _notStarted) {
        port.send('ReadFile failed');
        return;
      }
      if (ok == 0 && status.value == _statusPending) {
        while (stop.value == 0 &&
            _kernel.waitForSingleObject(event, 100) != _waitObject0) {}
        if (stop.value != 0) {
          _kernel.cancelIo(handle);
          _kernel.getOverlappedResult(handle, ov.cast(), got, 1);
          return;
        }
      }
      if (_kernel.getOverlappedResult(handle, ov.cast(), got, 0) == 0) {
        port.send('Reading from the HID device failed (unplugged?)');
        return;
      }
      if (got.value > 0) {
        sendReport(port, Uint8List.fromList(buf.asTypedList(got.value)));
      }
    }
  } finally {
    _kernel.closeHandle(event);
    _kernel.closeHandle(handle);
    calloc.free(buf);
    calloc.free(ov);
    calloc.free(got);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

bool _invalid(Pointer<Void> h) => h.address == -1 || h == nullptr;

Pointer<Void> _createFile(String path, int access, int flags) {
  final p = path.toNativeUtf16();
  try {
    return _kernel.createFile(
      p,
      access,
      _fileShareRead | _fileShareWrite,
      nullptr,
      _openExisting,
      flags,
      nullptr,
    );
  } finally {
    calloc.free(p);
  }
}

/// (InputReportByteLength, OutputReportByteLength), zeros when unknown.
(int, int) _reportLengths(Pointer<Void> h) {
  final preparsed = calloc<Pointer<Void>>();
  final caps = calloc<Uint8>(_hidpCapsSize);
  try {
    if (_hid.getPreparsedData(h, preparsed) == 0) return (0, 0);
    try {
      if (_hid.getCaps(preparsed.value, caps) != _hidpStatusSuccess) {
        return (0, 0);
      }
      return ((caps + 4).cast<Uint16>().value, (caps + 6).cast<Uint16>().value);
    } finally {
      _hid.freePreparsedData(preparsed.value);
    }
  } finally {
    calloc.free(preparsed);
    calloc.free(caps);
  }
}

String _string(
  Pointer<Void> h,
  int Function(Pointer<Void>, Pointer<Void>, int) getter,
) {
  const chars = 256;
  final buf = calloc<Uint16>(chars);
  try {
    if (getter(h, buf.cast(), chars * 2) == 0) return '';
    return buf.cast<Utf16>().toDartString();
  } finally {
    calloc.free(buf);
  }
}

const _digcfPresent = 0x02, _digcfDeviceInterface = 0x10;
const _spInterfaceDataSize = 32; // SP_DEVICE_INTERFACE_DATA, 64-bit
const _overlappedSize = 32; // OVERLAPPED, 64-bit
const _hidpCapsSize = 64;
const _hidpStatusSuccess = 0x00110000;
const _genericRead = 0x80000000, _genericWrite = 0x40000000;
const _fileShareRead = 1, _fileShareWrite = 2;
const _openExisting = 3;
const _fileFlagOverlapped = 0x40000000;
const _statusPending = 0x103;
const _notStarted = -1; // sentinel: ReadFile didn't even queue the request
const _waitObject0 = 0;

// ---------------------------------------------------------------------------
// Bindings (resolved lazily, per isolate, only on Windows)
// ---------------------------------------------------------------------------

final _kernel = _Kernel32(DynamicLibrary.open('kernel32.dll'));
final _hid = _HidDll(DynamicLibrary.open('hid.dll'));
final _setup = _SetupApi(DynamicLibrary.open('setupapi.dll'));

typedef _H = Pointer<Void>;

class _Kernel32 {
  _Kernel32(DynamicLibrary l)
    : createFile = l
          .lookupFunction<
            _H Function(Pointer<Utf16>, Uint32, Uint32, _H, Uint32, Uint32, _H),
            _H Function(Pointer<Utf16>, int, int, _H, int, int, _H)
          >('CreateFileW'),
      closeHandle = l.lookupFunction<Int32 Function(_H), int Function(_H)>(
        'CloseHandle',
      ),
      readFile = l
          .lookupFunction<
            Int32 Function(_H, _H, Uint32, Pointer<Uint32>, _H),
            int Function(_H, _H, int, Pointer<Uint32>, _H)
          >('ReadFile'),
      writeFile = l
          .lookupFunction<
            Int32 Function(_H, _H, Uint32, Pointer<Uint32>, _H),
            int Function(_H, _H, int, Pointer<Uint32>, _H)
          >('WriteFile'),
      createEvent = l
          .lookupFunction<
            _H Function(_H, Int32, Int32, _H),
            _H Function(_H, int, int, _H)
          >('CreateEventW'),
      resetEvent = l.lookupFunction<Int32 Function(_H), int Function(_H)>(
        'ResetEvent',
      ),
      waitForSingleObject = l
          .lookupFunction<Uint32 Function(_H, Uint32), int Function(_H, int)>(
            'WaitForSingleObject',
          ),
      cancelIo = l.lookupFunction<Int32 Function(_H), int Function(_H)>(
        'CancelIo',
      ),
      getOverlappedResult = l
          .lookupFunction<
            Int32 Function(_H, _H, Pointer<Uint32>, Int32),
            int Function(_H, _H, Pointer<Uint32>, int)
          >('GetOverlappedResult');

  final _H Function(Pointer<Utf16>, int, int, _H, int, int, _H) createFile;
  final int Function(_H) closeHandle;
  final int Function(_H, _H, int, Pointer<Uint32>, _H) readFile;
  final int Function(_H, _H, int, Pointer<Uint32>, _H) writeFile;
  final _H Function(_H, int, int, _H) createEvent;
  final int Function(_H) resetEvent;
  final int Function(_H, int) waitForSingleObject;
  final int Function(_H) cancelIo;
  final int Function(_H, _H, Pointer<Uint32>, int) getOverlappedResult;
}

class _HidDll {
  _HidDll(DynamicLibrary l)
    : getHidGuid = l
          .lookupFunction<
            Void Function(Pointer<Uint8>),
            void Function(Pointer<Uint8>)
          >('HidD_GetHidGuid'),
      getAttributes = l
          .lookupFunction<
            Uint8 Function(_H, Pointer<Uint8>),
            int Function(_H, Pointer<Uint8>)
          >('HidD_GetAttributes'),
      getProductString = l
          .lookupFunction<
            Uint8 Function(_H, _H, Uint32),
            int Function(_H, _H, int)
          >('HidD_GetProductString'),
      getManufacturerString = l
          .lookupFunction<
            Uint8 Function(_H, _H, Uint32),
            int Function(_H, _H, int)
          >('HidD_GetManufacturerString'),
      getPreparsedData = l
          .lookupFunction<
            Uint8 Function(_H, Pointer<Pointer<Void>>),
            int Function(_H, Pointer<Pointer<Void>>)
          >('HidD_GetPreparsedData'),
      freePreparsedData = l
          .lookupFunction<Uint8 Function(_H), int Function(_H)>(
            'HidD_FreePreparsedData',
          ),
      getCaps = l
          .lookupFunction<
            Int32 Function(_H, Pointer<Uint8>),
            int Function(_H, Pointer<Uint8>)
          >('HidP_GetCaps');

  final void Function(Pointer<Uint8>) getHidGuid;
  final int Function(_H, Pointer<Uint8>) getAttributes;
  final int Function(_H, _H, int) getProductString;
  final int Function(_H, _H, int) getManufacturerString;
  final int Function(_H, Pointer<Pointer<Void>>) getPreparsedData;
  final int Function(_H) freePreparsedData;
  final int Function(_H, Pointer<Uint8>) getCaps;
}

class _SetupApi {
  _SetupApi(DynamicLibrary l)
    : getClassDevs = l
          .lookupFunction<
            _H Function(Pointer<Uint8>, _H, _H, Uint32),
            _H Function(Pointer<Uint8>, _H, _H, int)
          >('SetupDiGetClassDevsW'),
      enumInterfaces = l
          .lookupFunction<
            Int32 Function(_H, _H, Pointer<Uint8>, Uint32, Pointer<Uint8>),
            int Function(_H, _H, Pointer<Uint8>, int, Pointer<Uint8>)
          >('SetupDiEnumDeviceInterfaces'),
      interfaceDetail = l
          .lookupFunction<
            Int32 Function(
              _H,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Uint32,
              Pointer<Uint32>,
              _H,
            ),
            int Function(
              _H,
              Pointer<Uint8>,
              Pointer<Uint8>,
              int,
              Pointer<Uint32>,
              _H,
            )
          >('SetupDiGetDeviceInterfaceDetailW'),
      destroyList = l.lookupFunction<Int32 Function(_H), int Function(_H)>(
        'SetupDiDestroyDeviceInfoList',
      );

  final _H Function(Pointer<Uint8>, _H, _H, int) getClassDevs;
  final int Function(_H, _H, Pointer<Uint8>, int, Pointer<Uint8>)
  enumInterfaces;
  final int Function(
    _H,
    Pointer<Uint8>,
    Pointer<Uint8>,
    int,
    Pointer<Uint32>,
    _H,
  )
  interfaceDetail;
  final int Function(_H) destroyList;
}
