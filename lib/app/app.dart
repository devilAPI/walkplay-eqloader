import 'package:flutter/material.dart';

import '../app_info.dart';
import '../hid/hid.dart';
import '../state/profile_library.dart';
import '../state/settings.dart';
import '../state/store.dart';
import '../ui/home/home_page.dart';
import '../ui/theme.dart';

class EqLoaderApp extends StatefulWidget {
  /// Where settings and the profile library live; null keeps them in memory
  /// (tests).
  final KeyValueStore? store;

  /// USB HID access; null picks the platform's (tests pass a fake).
  final HidBackend? backend;

  const EqLoaderApp({super.key, this.store, this.backend});

  @override
  State<EqLoaderApp> createState() => _EqLoaderAppState();
}

class _EqLoaderAppState extends State<EqLoaderApp> {
  late final KeyValueStore _store = widget.store ?? MemoryStore();
  late final _settings = Settings(_store);
  late final _library = ProfileLibrary(_store);

  @override
  void dispose() {
    _settings.dispose();
    _library.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: appName,
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: HomePage(
      settings: _settings,
      library: _library,
      backend: widget.backend,
    ),
  );
}
