/// Native I/O for the AutoEQ database: dart:io HTTP, files on disk.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const supportsLocalDatabase = true;

Future<File> _configFile() async => File(
  p.join((await getApplicationSupportDirectory()).path, 'autoeq_db.json'),
);

Future<File> _cacheFile(String repoPath) async => File(
  p.joinAll([
    (await getApplicationCacheDirectory()).path,
    'autoeq_db',
    ...repoPath.split('/'),
  ]),
);

Future<String?> readDbSetting() async {
  try {
    final path = jsonDecode(await (await _configFile()).readAsString())['path'];
    return path is String ? path : null;
  } catch (_) {
    return null;
  }
}

Future<void> writeDbSetting(String source) async {
  try {
    final f = await _configFile();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'path': source}));
  } catch (_) {}
}

bool localFolderExists(String path) => Directory(path).existsSync();

/// Paths of all files under [root].
Stream<String> listFilesRecursive(String root) =>
    Directory(root)
        .list(recursive: true, followLinks: false)
        .where((e) => e is File)
        .map((e) => e.path);

Future<String> readLocalFile(String path) => File(path).readAsString();

Future<List<int>?> readCache(String repoPath) async {
  final f = await _cacheFile(repoPath);
  return await f.exists() ? f.readAsBytes() : null;
}

Future<void> writeCache(String repoPath, List<int> content) async {
  final f = await _cacheFile(repoPath);
  await f.parent.create(recursive: true);
  await f.writeAsBytes(content);
}

final _http = HttpClient()..connectionTimeout = const Duration(seconds: 20);

Future<List<int>> httpGet(String url, {bool json = false}) async {
  final req = await _http.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, 'eqloader');
  if (json) {
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
  }
  final resp = await req.close().timeout(const Duration(seconds: 20));
  final body = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  if (resp.statusCode != 200) {
    throw HttpException('HTTP ${resp.statusCode} for $url${_detail(body)}');
  }
  return body;
}

String _detail(List<int> body) {
  try {
    return ': ${jsonDecode(utf8.decode(body))['message']}';
  } catch (_) {
    return '';
  }
}
