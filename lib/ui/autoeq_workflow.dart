import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/autoeq.dart';
import '../core/autoeq_db.dart';
import '../core/band.dart';
import '../core/profile.dart';
import '../state/eq_model.dart';
import 'dialogs.dart';
import 'files.dart';
import 'theme.dart';

/// What the AutoEQ workflow needs from the main page.
abstract interface class TaskHost {
  BuildContext get context;
  EqModel get model;
  int get maxFilters;

  /// Run [work]; returns its result, or null after a failure (which is
  /// logged, and shown as [error] (title, message) if given).
  Future<T?> runTask<T>(
    Future<T> Function() work, {
    (String, String)? busy,
    (String, String)? error,
  });
}

const _curveExtensions = ['txt', 'csv'];

/// The GUI side of AutoEQ: pick a measurement (online database or local
/// folder), pick a target, run the optimizer — or instead fetch a profile the
/// AutoEq project already computed for that model.
class AutoEqWorkflow {
  final TaskHost host;
  AutoEqWorkflow(this.host);

  String? _dbSource; // "online" or a folder, once an index is loaded
  List<DbEntry>? _modelIndex;
  List<DbEntry>? _targetIndex;

  BuildContext get _ctx => host.context;
  void _log(String s) => host.model.log(s);

  // ---- entry points ----------------------------------------------------

  Future<void> compute() async {
    final picked = await _pickModel();
    if (picked == null) return;
    final List<Point> measurement;
    try {
      measurement = parseFrequencyResponse(
        picked.content,
        source: picked.entry?.label ?? 'measurement file',
      );
    } catch (e) {
      if (_ctx.mounted) {
        await showInfo(_ctx, 'AutoEQ', 'Could not read measurement file:\n$e');
      }
      return;
    }
    final target = await _pickTarget();
    if (target == null) return;
    await _run(measurement, target.points);
  }

  Future<void> loadPrecomputed() async {
    final picked = await _pickModel();
    if (picked == null || !_ctx.mounted) return;
    final entry = picked.entry;
    if (entry == null || !entry.remote) {
      await showInfo(
        _ctx,
        'Pre-computed Profile',
        'Pre-computed profiles are only available for models picked from '
            'the online AutoEQ database, not local files/folders.',
      );
      return;
    }

    // entry.path is "measurements/<source>/data/<category>/<model>.csv"
    final source = entry.path.split('/')[1];
    final model = entry.label;
    final candidates = await host.runTask(
      () => fetchPrecomputedProfiles(source, model, _log),
      busy: (
        'Pre-computed Profile',
        'Looking up pre-computed EQ profile(s) for $model...',
      ),
      error: ('Pre-computed Profile', 'Lookup failed'),
    );
    if (candidates == null || !_ctx.mounted) return;

    String? content;
    DbEntry? variant;
    if (candidates.isEmpty) {
      await showInfo(
        _ctx,
        'Pre-computed Profile',
        "No pre-computed ParametricEQ.txt found for $model under '$source'.",
      );
      return;
    } else if (candidates.length == 1) {
      variant = candidates.single;
      content = await host.runTask(
        () => fetchRemoteFile(variant!.path),
        busy: ('Pre-computed Profile', 'Downloading ${variant.label}...'),
        error: ('Pre-computed Profile', 'Could not load profile'),
      );
    } else {
      final result = await SearchDialog.show(
        _ctx,
        SearchDialog(title: 'Select Target Variant', items: () => candidates),
      );
      variant = result?.entry;
      content = result?.content;
    }
    if (content == null || variant == null) return;

    try {
      final profile = parseProfile(content, source: variant.path);
      host.model.setFilters(profile.filters, profile.preamp);
      _log('Loaded pre-computed profile (${variant.label})');
    } catch (e) {
      if (_ctx.mounted) {
        await showInfo(
          _ctx,
          'Pre-computed Profile',
          'Could not load profile:\n$e',
        );
      }
    }
  }

  // ---- compute ---------------------------------------------------------

  Future<void> _run(List<Point> measurement, List<Point>? target) async {
    final maxFilters = host.maxFilters;
    final result = await host.runTask(
      () async {
        _log('Running AutoEQ optimization, this may take a while...');
        final r = await _computeInIsolate(measurement, target, maxFilters);
        _log(
          'AutoEQ generated ${r.filters.length} band(s), '
          'preamp ${r.preamp.toStringAsFixed(1)} dB',
        );
        return r;
      },
      busy: (
        'AutoEQ',
        'Running AutoEQ optimization...\n'
            'This can take a while depending on the number of filters.',
      ),
      error: ('AutoEQ', 'AutoEQ failed'),
    );
    if (result != null) host.model.setFilters(result.filters, result.preamp);
  }

  /// The target curve (points null = flat), or null if cancelled.
  Future<({List<Point>? points})?> _pickTarget() async {
    final choice = await askChoice<String>(
      _ctx,
      'AutoEQ Target',
      'Choose the target curve AutoEQ should reshape your measurement towards.',
      [
        ('Flat (0 dB)', 'flat', ButtonKind.normal),
        ('Search AutoEQ Targets...', 'online', ButtonKind.accent),
        ('Load Target File...', 'file', ButtonKind.normal),
        ('Cancel', null, ButtonKind.normal),
      ],
    );
    String? content;
    String source = 'target file';
    switch (choice) {
      case 'flat':
        return (points: null);
      case 'online':
        if (_targetIndex == null) {
          _targetIndex = await host.runTask(
            () async {
              _log('Fetching AutoEQ target curve list from GitHub...');
              final index = await fetchTargetsIndex(_log);
              _log('Fetched ${index.length} target curve(s).');
              return index;
            },
            busy: (
              'AutoEQ Targets',
              'Fetching target curve list from GitHub...',
            ),
            error: ('AutoEQ Targets', 'Could not fetch the target list'),
          );
          if (_targetIndex == null) return null;
        }
        if (!_ctx.mounted) return null;
        final result = await SearchDialog.show(
          _ctx,
          SearchDialog(
            title: 'Search AutoEQ Targets',
            items: () => _targetIndex!,
          ),
        );
        content = result?.content;
        source = result?.entry?.label ?? source;
      case 'file':
        final picked = await pickTextFile(
          'Select Target Curve File (freq, dB per line)',
          _curveExtensions,
        );
        content = picked?.content;
        source = picked?.name ?? source;
    }
    if (content == null) return null;
    try {
      return (points: parseFrequencyResponse(content, source: source));
    } catch (e) {
      if (_ctx.mounted) {
        await showInfo(_ctx, 'AutoEQ', 'Could not read target file:\n$e');
      }
      return null;
    }
  }

  // ---- measurement database ----------------------------------------------

  /// A measurement file picked from the database (or browsed), or null.
  Future<SearchResult?> _pickModel() async {
    if (_modelIndex == null) {
      final source = await loadDbSource() ?? await _askDbSource();
      if (source == null || !await _openDb(source)) return null;
    }
    return _modelSearch();
  }

  /// "online", a local folder, or null.
  Future<String?> _askDbSource() async {
    if (!_ctx.mounted) return null;
    final choice = await askChoice<String>(
      _ctx,
      'AutoEQ Model Database',
      'Search headphone/IEM measurements in the online AutoEQ database on '
          'GitHub (jaakkopasanen/AutoEq), or in a local folder of measurement '
          '.txt/.csv files?',
      [
        ('Download Online Database', 'online', ButtonKind.accent),
        ('Choose Local Folder...', 'local', ButtonKind.normal),
        ('Cancel', null, ButtonKind.normal),
      ],
    );
    if (choice == 'local') {
      return pickDirectory('Select Measurement Database Folder');
    }
    return choice;
  }

  /// Load and remember the model index of [source]; false on failure.
  Future<bool> _openDb(String source) async {
    final index = await host.runTask(
      () async {
        if (source != 'online') return buildLocalIndex(source);
        _log('Fetching AutoEQ database listing from GitHub...');
        final index = await fetchOnlineIndex(_log);
        _log('Fetched ${index.length} model(s) from the online database.');
        return index;
      },
      busy: source == 'online'
          ? ('AutoEQ Model Database', 'Fetching model list from GitHub...')
          : ('AutoEQ Model Database', 'Indexing $source...'),
      error: source == 'online'
          ? ('AutoEQ Model Database', 'Could not fetch the online database')
          : ('AutoEQ Model Database', 'Could not read the folder'),
    );
    if (index == null) return false;
    _modelIndex = index;
    _dbSource = source;
    await saveDbSource(source);
    return true;
  }

  Future<SearchResult?> _modelSearch() async {
    if (!_ctx.mounted) return null;
    return SearchDialog.show(
      _ctx,
      SearchDialog(
        title: 'Search Headphone Model',
        items: () => _modelIndex ?? const [],
        showSubtitle: true,
        statusSuffix: () => _dbSource == null
            ? ''
            : ' in ${_dbSource == 'online' ? 'online' : p.basename(_dbSource!)}',
        extraButtons: [
          (
            'Browse File Instead...',
            (c) async {
              final picked = await pickTextFile(
                'Select Measurement File (freq, dB per line)',
                _curveExtensions,
              );
              if (picked != null) c.finish(picked.content, null);
            },
          ),
          (
            'Change Database...',
            (c) async {
              final source = await _askDbSource();
              if (source == null) return;
              if (source == 'online') {
                c.setStatus('Fetching online database...');
              }
              await _openDb(source);
              c.refresh();
            },
          ),
        ],
      ),
    );
  }
}

/// Top-level so the isolate closure captures nothing but its arguments.
Future<AutoEqResult> _computeInIsolate(
  List<Point> measurement,
  List<Point>? target,
  int maxFilters,
) => Isolate.run(() => autoeqCompute(measurement, target, maxFilters));
