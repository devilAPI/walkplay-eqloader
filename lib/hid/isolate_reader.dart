import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'hid.dart';

/// Message a reader isolate gets: where to send reports, the address of an
/// int32 stop flag it must poll, and backend-specific [T] arguments.
typedef ReaderArgs<T> = (SendPort reports, int stopFlag, T args);

/// Sends one input report (report id first) from a reader isolate.
void sendReport(SendPort port, Uint8List report) =>
    port.send(TransferableTypedData.fromList([report]));

/// A [HidConnection] whose input reports come from a background isolate
/// that blocks in native reads, so the UI isolate never does.
///
/// The reader isolate sends each report with [sendReport], sends any other
/// object as a fatal error, and returns once the stop flag becomes nonzero.
abstract class IsolateReadConnection implements HidConnection {
  final _reports = Queue<Uint8List>();
  Completer<void>? _waiter;
  Object? _error;
  final _messages = ReceivePort();
  final _exit = ReceivePort();
  final Pointer<Int32> _stop = calloc<Int32>();
  bool _stopped = false;

  Future<void> startReader<T>(
    void Function(ReaderArgs<T>) entry,
    T args,
  ) async {
    _messages.listen((m) {
      if (m is TransferableTypedData) {
        _reports.add(m.materialize().asUint8List());
      } else {
        _error = m; // an error string, or [error, stack] from onError
      }
      _wake();
    });
    await Isolate.spawn(
      entry,
      (_messages.sendPort, _stop.address, args),
      onExit: _exit.sendPort,
      onError: _messages.sendPort,
    );
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void checkAlive() {
    if (_error != null) throw StateError('HID device is gone: $_error');
  }

  @override
  Future<Uint8List?> read(Duration timeout) async {
    if (_reports.isEmpty) {
      checkAlive();
      final waiter = _waiter ??= Completer<void>();
      await waiter.future.timeout(timeout, onTimeout: () {});
    }
    return _reports.isEmpty ? null : _reports.removeFirst();
  }

  /// Ask the reader to stop and wait until its isolate has exited.
  Future<void> stopReader() async {
    if (_stopped) return;
    _stopped = true;
    _stop.value = 1;
    await _exit.first;
    _messages.close();
    calloc.free(_stop);
  }
}
