/// AutoEQ measurement database (online AutoEq repo or a local folder).
///
/// Index entries are [DbEntry]s: `path` is a local file, or for remote
/// entries a repo-relative path fetched (and cached) by [fetchRemoteFile].
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DbEntry {
  final String label;
  final String path;
  final String subtitle;
  final bool remote;
  const DbEntry(this.label, this.path, this.subtitle, this.remote);
}

// Raw per-model measurements live under measurements/<source>/data/<category>/
// <model>.csv as plain "frequency,raw" CSVs; results/<source>/ holds the
// project's own computed EQs.
const _repo = 'jaakkopasanen/AutoEq';
const _branch = 'master';
const _apiBase = 'https://api.github.com/repos/$_repo';
const _rawBase = 'https://raw.githubusercontent.com/$_repo/$_branch/';
const _measurementsDir = 'measurements';
const _targetsDir = 'targets';
const _resultsDir = 'results';

// Result files, not raw measurements — skip these when indexing a local folder.
const _skipSuffixes = ['parametriceq', 'graphiceq', 'fixedbandeq', ' eq'];

typedef Logger = void Function(String line);

Future<File> _configFile() async => File(
  p.join((await getApplicationSupportDirectory()).path, 'autoeq_db.json'),
);

Future<Directory> _cacheDir() async =>
    Directory(p.join((await getApplicationCacheDirectory()).path, 'autoeq_db'));

/// The last-used measurement source ('online' or a folder path).
Future<String?> loadDbSource() async {
  try {
    final path = jsonDecode(await (await _configFile()).readAsString())['path'];
    if (path == 'online' ||
        (path is String && path.isNotEmpty && Directory(path).existsSync())) {
      return path as String;
    }
  } catch (_) {}
  return null;
}

Future<void> saveDbSource(String source) async {
  try {
    final f = await _configFile();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'path': source}));
  } catch (_) {}
}

List<DbEntry> _sorted(Iterable<DbEntry> entries) =>
    entries.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

/// Recursively index measurement .txt/.csv files under [root] by model name
/// (the file name); the containing folder becomes the subtitle.
Future<List<DbEntry>> buildLocalIndex(String root) async {
  final entries = <DbEntry>[];
  await for (final e in Directory(
    root,
  ).list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final ext = p.extension(e.path).toLowerCase();
    if (ext != '.txt' && ext != '.csv') continue;
    final stem = p.basenameWithoutExtension(e.path);
    if (_skipSuffixes.any(stem.toLowerCase().endsWith)) continue;
    entries.add(
      DbEntry(stem, e.path, p.relative(p.dirname(e.path), from: root), false),
    );
  }
  return _sorted(entries);
}

final _http = HttpClient()..connectionTimeout = const Duration(seconds: 20);

Future<List<int>> _get(String url, {bool json = false}) async {
  final req = await _http.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, 'eqloader');
  if (json) {
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
  }
  final resp = await req.close().timeout(const Duration(seconds: 20));
  final body = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  if (resp.statusCode != 200) {
    var detail = '';
    try {
      detail = ': ${jsonDecode(utf8.decode(body))['message']}';
    } catch (_) {}
    throw HttpException('HTTP ${resp.statusCode} for $url$detail');
  }
  return body;
}

Future<Map<String, dynamic>> _githubGet(String url) async =>
    jsonDecode(utf8.decode(await _get(url, json: true)))
        as Map<String, dynamic>;

/// Blob paths under one repo folder (by its own tree sha rather than the
/// whole repo's recursive tree, which GitHub truncates). [dirPath] may be
/// nested; it is walked one level at a time.
Future<List<String>> _githubSubtree(String dirPath, Logger log) async {
  var treeSha = _branch;
  for (final part in dirPath.split('/')) {
    final listing = await _githubGet('$_apiBase/git/trees/$treeSha');
    final entry = (listing['tree'] as List)
        .cast<Map>()
        .where((e) => e['path'] == part && e['type'] == 'tree')
        .firstOrNull;
    if (entry == null) throw StateError("'$dirPath' folder not found in repo");
    treeSha = entry['sha'] as String;
  }
  final sub = await _githubGet('$_apiBase/git/trees/$treeSha?recursive=1');
  if (sub['truncated'] == true) {
    log(
      "Warning: GitHub '$dirPath' listing was truncated; some entries may be missing.",
    );
  }
  return [
    for (final e in (sub['tree'] as List).cast<Map>())
      if (e['type'] == 'blob') e['path'] as String,
  ];
}

/// The AutoEq repo's raw measurement files (names only; content is
/// downloaded lazily, on selection).
Future<List<DbEntry>> fetchOnlineIndex(Logger log) async => _sorted([
  for (final path in await _githubSubtree(_measurementsDir, log))
    if (path.contains('/data/') && path.endsWith('.csv'))
      DbEntry(
        p.posix.basenameWithoutExtension(path),
        '$_measurementsDir/$path',
        p.posix.dirname(path),
        true,
      ),
]);

/// The AutoEq repo's named target curves (Harman, diffuse-field, ...).
Future<List<DbEntry>> fetchTargetsIndex(Logger log) async => _sorted([
  for (final path in await _githubSubtree(_targetsDir, log))
    if (path.endsWith('.csv'))
      DbEntry(
        p.posix.basenameWithoutExtension(path),
        '$_targetsDir/$path',
        '',
        true,
      ),
]);

/// ParametricEQ.txt file(s) the AutoEq project already computed for
/// [modelStem] under results/<source>/ — one per target variant it used.
Future<List<DbEntry>> fetchPrecomputedProfiles(
  String source,
  String modelStem,
  Logger log,
) async {
  final matches = <DbEntry>[];
  for (final path in await _githubSubtree('$_resultsDir/$source', log)) {
    final parent = p.posix.dirname(path);
    if (!path.endsWith('ParametricEQ.txt') ||
        p.posix.basename(parent) != modelStem) {
      continue;
    }
    final variant = p.posix.dirname(parent);
    matches.add(
      DbEntry(
        variant == '.' || variant.isEmpty ? source : '$source / $variant',
        '$_resultsDir/$source/$path',
        '',
        true,
      ),
    );
  }
  return _sorted(matches);
}

/// Download (and locally cache) one file from the AutoEq repo.
Future<String> fetchRemoteFile(String repoPath) async {
  final cache = File(
    p.joinAll([(await _cacheDir()).path, ...repoPath.split('/')]),
  );
  if (await cache.exists()) return cache.readAsString();

  final url = _rawBase + repoPath.split('/').map(Uri.encodeComponent).join('/');
  final content = await _get(url);
  await cache.parent.create(recursive: true);
  await cache.writeAsBytes(content);
  return utf8.decode(content, allowMalformed: true);
}

/// Contents of an index entry (downloading remote ones).
Future<String> loadEntry(DbEntry e) =>
    e.remote ? fetchRemoteFile(e.path) : File(e.path).readAsString();
