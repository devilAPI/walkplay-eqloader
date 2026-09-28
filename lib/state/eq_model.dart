import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/band.dart';

typedef _Snapshot = (List<Band> filters, String preamp, int selected);

/// Undo/redo stacks of opaque state snapshots.
class UndoHistory<T> {
  final _undo = <T>[];
  final _redo = <T>[];

  /// Remember [state] (taken before a change) as one undo step.
  void record(T state) {
    _undo.add(state);
    _redo.clear();
  }

  /// State to restore, or null; [current] becomes redoable.
  T? undo(T current) {
    if (_undo.isEmpty) return null;
    _redo.add(current);
    return _undo.removeLast();
  }

  T? redo(T current) {
    if (_redo.isEmpty) return null;
    _undo.add(current);
    return _redo.removeLast();
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
}

/// The EQ being edited: bands, selection, preamp text, undo history and log.
///
/// [selection] mirrors the desktop app's multi-select band list; [selected]
/// is the primary band whose values the editor fields show.
class EqModel extends ChangeNotifier {
  List<Band> filters = [newBand()];
  int selected = 0;
  Set<int> selection = {0};
  String preamp = '0';

  /// [preamp] as typed, or 0 while it isn't a number.
  double get preampDb => parseDoubleText(preamp, 0)!;

  /// Bumped whenever the editor fields must reload from the primary band.
  int fieldsRevision = 0;

  final _history = UndoHistory<_Snapshot>();
  bool _editorRecorded = false;

  final logLines = <String>[];

  /// Bumped on every [log]; [logLines] stops growing once capped.
  int logRevision = 0;

  void log(String text) {
    logRevision++;
    logLines.addAll(text.trimRight().split('\n'));
    if (logLines.length > 2000) logLines.removeRange(0, logLines.length - 2000);
    notifyListeners();
  }

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

  /// Indices the editor fields apply to: the list selection, else the primary band.
  List<int> get effectiveSelection {
    final sel = selection.where((i) => i < filters.length).toList()..sort();
    if (sel.isNotEmpty) return sel;
    return 0 <= selected && selected < filters.length ? [selected] : [];
  }

  Set<int> get highlighted => {...selection, selected};

  Band? get primary =>
      0 <= selected && selected < filters.length ? filters[selected] : null;

  void _reloadFields() {
    _editorRecorded = false;
    fieldsRevision++;
  }

  /// Select the primary band (and only it), reloading the fields.
  void _selectOnly(int index) {
    selected = filters.isEmpty ? -1 : index.clamp(0, filters.length - 1);
    selection = selected >= 0 ? {selected} : {};
    _reloadFields();
  }

  // ---- selection -------------------------------------------------------

  void select(int index) {
    _selectOnly(index);
    notifyListeners();
  }

  /// Ctrl-click / long-press: toggle [index] in the multi-selection.
  void toggleSelect(int index) {
    final sel = {...selection};
    if (!sel.remove(index)) sel.add(index);
    selection = sel;
    if (sel.contains(index)) {
      selected = index;
      _reloadFields();
    }
    notifyListeners();
  }

  /// Shift-click: extend the selection from the primary band to [index].
  void rangeSelect(int index) {
    final from = selected < 0 ? index : selected;
    final lo = from < index ? from : index, hi = from < index ? index : from;
    selection = {for (var i = lo; i <= hi; i++) i};
    selected = index;
    _reloadFields();
    notifyListeners();
  }

  // ---- edits -----------------------------------------------------------

  /// Live-apply one edited field to every selected band (one undo step per
  /// field-edit session, i.e. until the selection changes).
  void applyField(String field, Object value) {
    final sel = effectiveSelection;
    if (sel.isEmpty) return;
    if (!_editorRecorded) {
      _record();
      _editorRecorded = true;
    }
    for (final i in sel) {
      final f = filters[i];
      switch (field) {
        case 'type':
          f.type = value as String;
        case 'freq':
          f.freq = value as double;
        case 'gain':
          f.gain = value as double;
        case 'q':
          f.q = value as double;
      }
      f.disabled = null;
    }
    notifyListeners();
  }

  void setPreampText(String text, {bool record = false}) {
    if (record) _record();
    preamp = text;
    notifyListeners();
  }

  /// Replace the whole EQ (one undo step). [clean]: drop OFF bands and
  /// duplicates, for EQs from a file, the device or AutoEQ; library
  /// profiles come back exactly as they were saved.
  void setFilters(
    List<Band> newFilters,
    double newPreamp, {
    bool clean = true,
  }) {
    _record();
    filters = clean
        ? activeFilters(newFilters)
        : [for (final f in newFilters) f.copy()];
    preamp = fmtG(newPreamp);
    _selectOnly(0);
    notifyListeners();
  }

  void addBand([Band? band]) {
    _record();
    filters.add(band ?? newBand());
    _selectOnly(filters.length - 1);
    notifyListeners();
  }

  void removeBands(Iterable<int> indices) {
    final sorted = indices.toSet().toList()..sort();
    if (sorted.isEmpty) return;
    _record();
    for (final i in sorted.reversed) {
      filters.removeAt(i);
    }
    _selectOnly(sorted.first);
    notifyListeners();
  }

  void deleteSelected() =>
      removeBands(selection.where((i) => i < filters.length));

  void deleteAll() {
    _record();
    filters.clear();
    _selectOnly(-1);
    notifyListeners();
  }

  // ---- graph dragging --------------------------------------------------

  bool _dragRecorded = false;

  /// Grab an existing band. A plain selecting click must not create an undo
  /// step, so the snapshot waits for the first actual drag move.
  void beginDragExisting(int index) {
    _dragRecorded = false;
    _selectOnly(index);
    notifyListeners();
  }

  /// Create a band at the pointer; the pre-append snapshot also covers dragging it.
  void beginDragNew(double freq, double gain) {
    _record();
    _dragRecorded = true;
    filters.add(
      Band(type: 'PK', freq: roundTo(freq, 1), gain: roundTo(gain, 1), q: 1),
    );
    _selectOnly(filters.length - 1);
    notifyListeners();
  }

  /// Fires on every drag step; only the graph listens to it (see [graph]).
  final _graphTick = _Tick();
  Timer? _uiThrottle;

  /// What the graph repaints on: every model change plus every drag step.
  late final Listenable graph = Listenable.merge([this, _graphTick]);

  /// Move a band while dragging. The graph repaints every step; everything
  /// else (band list, editor fields) is refreshed at most every 100 ms and
  /// once more at [endDrag], so a drag doesn't rebuild half the UI per frame.
  void dragTo(int index, double freq, double gain) {
    if (index >= filters.length) return;
    if (!_dragRecorded) {
      _record();
      _dragRecorded = true;
    }
    filters[index]
      ..freq = roundTo(freq, 1)
      ..gain = roundTo(gain, 1)
      ..disabled = null;
    _graphTick.tick();
    _uiThrottle ??= Timer(const Duration(milliseconds: 100), _flushDrag);
  }

  void _flushDrag() {
    _uiThrottle?.cancel();
    _uiThrottle = null;
    fieldsRevision++;
    notifyListeners();
  }

  void endDrag() {
    _dragRecorded = false;
    if (_uiThrottle != null) _flushDrag();
  }

  @override
  void dispose() {
    _uiThrottle?.cancel();
    _graphTick.dispose();
    super.dispose();
  }

  // ---- undo ------------------------------------------------------------

  _Snapshot _capture() =>
      ([for (final f in filters) f.copy()], preamp, selected);

  void _restore(_Snapshot s) {
    filters = s.$1;
    preamp = s.$2;
    _selectOnly(s.$3.clamp(-1, filters.length - 1));
    notifyListeners();
  }

  void _record() => _history.record(_capture());

  void undo() {
    final s = _history.undo(_capture());
    if (s != null) _restore(s);
  }

  void redo() {
    final s = _history.redo(_capture());
    if (s != null) _restore(s);
  }
}

/// Python's "{:g}" for typical preamp values.
String fmtG(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  var s = v.toStringAsPrecision(6);
  if (s.contains('.') && !s.contains('e')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

/// int from user text (decimal or 0x-hex), else [fallback].
int? parseIntText(String? s, [int? fallback]) {
  final t = (s ?? '').trim().toLowerCase();
  if (t.startsWith('0x')) {
    return int.tryParse(t.substring(2), radix: 16) ?? fallback;
  }
  return int.tryParse(t) ?? fallback;
}

/// double from user text (decimal comma accepted), else [fallback].
double? parseDoubleText(String? s, [double? fallback]) =>
    double.tryParse((s ?? '').trim().replaceAll(',', '.')) ?? fallback;

class _Tick extends ChangeNotifier {
  void tick() => notifyListeners();
}
