import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'pwa.dart';

/// The deferred `beforeinstallprompt` event; web/index.html stores it.
@JS('eqloaderInstallPrompt')
external JSObject? get _installPrompt;

@JS('eqloaderInstallPrompt')
external set _installPrompt(JSObject? event);

PwaState pwaState() {
  if (web.window.matchMedia('(display-mode: standalone)').matches) {
    return PwaState.installed;
  }
  return _installPrompt != null ? PwaState.installable : PwaState.unavailable;
}

Future<bool> installPwa() async {
  final event = _installPrompt;
  if (event == null) return false;
  // An install prompt event can only be shown once.
  _installPrompt = null;
  event.callMethod('prompt'.toJS);
  final choice = await (event['userChoice']! as JSPromise<JSObject>).toDart;
  return (choice['outcome'] as JSString?)?.toDart == 'accepted';
}
