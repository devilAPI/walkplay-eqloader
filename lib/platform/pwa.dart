/// Installing the web app as a PWA; nothing to do outside the browser.
library;

import 'pwa_stub.dart' if (dart.library.js_interop) 'pwa_web.dart' as impl;

enum PwaState {
  /// Not the web app, or the browser offers no install prompt (yet).
  unavailable,

  /// The browser can install it: [installPwa] shows its prompt.
  installable,

  /// Running as the installed app.
  installed,
}

PwaState get pwaState => impl.pwaState();

/// Show the browser's install prompt; true when the user accepted.
Future<bool> installPwa() => impl.installPwa();
