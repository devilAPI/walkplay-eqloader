import 'package:shared_preferences/shared_preferences.dart';

/// Persistent string storage for settings and the profile library.
///
/// Reads are synchronous (everything is loaded at startup); writes are
/// fire-and-forget, so a failing disk never breaks the UI.
abstract interface class KeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
}

/// Non-persistent store: tests, and the fallback when storage is blocked.
class MemoryStore implements KeyValueStore {
  final _values = <String, String>{};

  @override
  String? getString(String key) => _values[key];

  @override
  Future<void> setString(String key, String value) async =>
      _values[key] = value;
}

/// shared_preferences: a JSON file on desktop, platform prefs on Android,
/// localStorage in the browser.
class PrefsStore implements KeyValueStore {
  final SharedPreferencesWithCache _prefs;
  PrefsStore._(this._prefs);

  static Future<KeyValueStore> open() async {
    try {
      return PrefsStore._(
        await SharedPreferencesWithCache.create(
          cacheOptions: const SharedPreferencesWithCacheOptions(),
        ),
      );
    } catch (_) {
      return MemoryStore();
    }
  }

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    try {
      await _prefs.setString(key, value);
    } catch (_) {}
  }
}
