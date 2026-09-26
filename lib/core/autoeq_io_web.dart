/// Browser I/O for the AutoEQ database: fetch(), localStorage, and an
/// in-memory download cache. Local measurement folders aren't available.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const supportsLocalDatabase = false;

const _settingKey = 'autoeq_db_source';
final _cache = <String, List<int>>{};

Future<String?> readDbSetting() async {
  try {
    return web.window.localStorage.getItem(_settingKey);
  } catch (_) {
    return null;
  }
}

Future<void> writeDbSetting(String source) async {
  try {
    web.window.localStorage.setItem(_settingKey, source);
  } catch (_) {}
}

bool localFolderExists(String path) => false;

Stream<String> listFilesRecursive(String root) =>
    throw UnsupportedError('Local folders are not available in the browser.');

Future<String> readLocalFile(String path) =>
    throw UnsupportedError('Local files are not available in the browser.');

Future<List<int>?> readCache(String repoPath) async => _cache[repoPath];

Future<void> writeCache(String repoPath, List<int> content) async =>
    _cache[repoPath] = content;

Future<List<int>> httpGet(String url, {bool json = false}) async {
  final headers = web.Headers();
  if (json) headers.set('Accept', 'application/vnd.github+json');
  final resp = await web.window
      .fetch(url.toJS, web.RequestInit(headers: headers))
      .toDart
      .timeout(const Duration(seconds: 20));
  final body = (await resp.arrayBuffer().toDart).toDart.asUint8List();
  if (resp.status != 200) {
    throw StateError('HTTP ${resp.status} for $url${_detail(body)}');
  }
  return body;
}

String _detail(Uint8List body) {
  try {
    return ': ${jsonDecode(utf8.decode(body))['message']}';
  } catch (_) {
    return '';
  }
}
