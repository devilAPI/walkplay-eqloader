import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/walkplay.dart';
import 'store.dart';

/// User preferences, persisted as one JSON object.
class Settings extends ChangeNotifier {
  static const _key = 'settings';

  final KeyValueStore _store;

  /// Draw the flat (EQ bypassed) reference line on the graph.
  bool showFlatReference = true;

  /// Show and edit Q as bandwidth in octaves.
  bool qAsBandwidth = false;

  /// Filter slots the device has; pushes are padded to this many.
  int maxFilters = defaultMaxFilters;

  /// Headroom the device's gain register keeps below the preamp.
  double bufferDb = defaultGlobalGainBuffer;

  Settings(this._store) {
    try {
      final j = jsonDecode(_store.getString(_key) ?? '{}');
      if (j is! Map) return;
      showFlatReference = _read(j['showFlatReference'], showFlatReference);
      qAsBandwidth = _read(j['qAsBandwidth'], qAsBandwidth);
      maxFilters = _read(j['maxFilters'], maxFilters);
      bufferDb = _read<num>(j['bufferDb'], bufferDb).toDouble();
    } catch (_) {}
  }

  static T _read<T>(Object? value, T fallback) => value is T ? value : fallback;

  void update({
    bool? showFlatReference,
    bool? qAsBandwidth,
    int? maxFilters,
    double? bufferDb,
  }) {
    this.showFlatReference = showFlatReference ?? this.showFlatReference;
    this.qAsBandwidth = qAsBandwidth ?? this.qAsBandwidth;
    this.maxFilters = maxFilters ?? this.maxFilters;
    this.bufferDb = bufferDb ?? this.bufferDb;
    _store.setString(
      _key,
      jsonEncode({
        'showFlatReference': this.showFlatReference,
        'qAsBandwidth': this.qAsBandwidth,
        'maxFilters': this.maxFilters,
        'bufferDb': this.bufferDb,
      }),
    );
    notifyListeners();
  }
}
