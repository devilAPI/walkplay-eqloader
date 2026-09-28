{{flutter_js}}
{{flutter_build_config}}

// No serviceWorkerSettings: Flutter's own service worker is deprecated (it
// only unregisters itself) and would replace web/sw.js, which index.html
// registers at the same scope.
_flutter.loader.load();
