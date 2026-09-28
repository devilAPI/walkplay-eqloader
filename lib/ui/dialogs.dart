import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/autoeq_db.dart';
import 'theme.dart';

typedef ChoiceButton<T> = (String label, T? value, ButtonKind kind);

/// Modal message with a row of buttons. Returns the clicked button's value,
/// or null on Escape / dismissing. [enter] is the value Enter picks; [focus]
/// the label of the button that gets keyboard focus.
Future<T?> askChoice<T>(
  BuildContext context,
  String title,
  String message,
  List<ChoiceButton<T>> buttons, {
  T? enter,
  String? focus,
}) {
  return showDialog<T>(
    context: context,
    builder: (context) {
      Widget dialog = AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(child: Text(message)),
        ),
        actionsOverflowButtonSpacing: 6,
        actions: [
          for (final (label, value, kind) in buttons)
            FilledButton(
              autofocus: label == focus,
              style: styleFor(kind),
              onPressed: () => Navigator.of(context).pop(value),
              child: Text(label),
            ),
        ],
      );
      if (enter != null) {
        dialog = CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter): () =>
                Navigator.of(context).pop(enter),
            const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
                Navigator.of(context).pop(enter),
          },
          child: Focus(autofocus: focus == null, child: dialog),
        );
      }
      return dialog;
    },
  );
}

Future<bool> askYesNo(
  BuildContext context,
  String title,
  String message,
) async =>
    await askChoice<bool>(context, title, message, [
      ('No', false, ButtonKind.normal),
      ('Yes', true, ButtonKind.accent),
    ], enter: true) ==
    true;

Future<void> showInfo(BuildContext context, String title, String message) =>
    askChoice<bool>(
      context,
      title,
      message,
      [('OK', true, ButtonKind.accent)],
      enter: true,
      focus: 'OK',
    );

/// Ask for a line of text; null when cancelled or left blank.
Future<String?> askText(
  BuildContext context,
  String title,
  String label, {
  String initial = '',
  String confirm = 'OK',
}) async {
  final text = await showDialog<String>(
    context: context,
    builder: (_) => _TextDialog(title, label, initial, confirm),
  );
  final trimmed = text?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Owns its controller: the dialog still builds during its exit animation.
class _TextDialog extends StatefulWidget {
  final String title, label, initial, confirm;
  const _TextDialog(this.title, this.label, this.initial, this.confirm);

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title, style: const TextStyle(fontSize: 16)),
    content: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 440),
      child: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        style: styleFor(ButtonKind.accent),
        onPressed: _submit,
        child: Text(widget.confirm),
      ),
    ],
  );
}

/// Modal, not user-closable spinner; returns a function that closes it.
VoidCallback showBusy(BuildContext context, String title, String message) {
  final navigator = Navigator.of(context);
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message),
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
    ),
  ).whenComplete(() => open = false);
  return () {
    if (open) navigator.pop();
  };
}

/// Result of [SearchDialog]: the chosen file's contents and its index entry
/// (null for a manually browsed file).
class SearchResult {
  final String content;
  final DbEntry? entry;
  const SearchResult(this.content, this.entry);
}

/// Controls handed to extra buttons of a [SearchDialog].
class SearchDialogControls {
  final void Function(String content, DbEntry? entry) finish;
  final VoidCallback refresh;
  final void Function(String) setStatus;
  final BuildContext context;
  SearchDialogControls(this.finish, this.refresh, this.setStatus, this.context);
}

typedef SearchExtraButton = (
  String label,
  Future<void> Function(SearchDialogControls controls) onPressed,
);

/// Modal type-to-filter list over index entries. Picking a remote entry
/// downloads it first. When [returnEntryOnly] is set, the entry is returned
/// without loading it (content is then empty).
class SearchDialog extends StatefulWidget {
  final String title;
  final List<DbEntry> Function() items;
  final bool showSubtitle;
  final String Function() statusSuffix;
  final List<SearchExtraButton> extraButtons;
  final bool returnEntryOnly;

  const SearchDialog({
    super.key,
    required this.title,
    required this.items,
    this.showSubtitle = false,
    this.statusSuffix = _noSuffix,
    this.extraButtons = const [],
    this.returnEntryOnly = false,
  });

  static String _noSuffix() => '';

  static Future<SearchResult?> show(
    BuildContext context,
    SearchDialog dialog,
  ) => showDialog<SearchResult>(context: context, builder: (_) => dialog);

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  static const maxRows = 300;

  final _query = TextEditingController();
  List<DbEntry> _filtered = [];
  int _sel = 0;
  bool _busy = false;
  String? _statusOverride;

  @override
  void initState() {
    super.initState();
    _refresh();
    _query.addListener(() => setState(_refresh));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _refresh() {
    _statusOverride = null;
    final terms = _query.text.trim().toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((t) => t.isEmpty);
    _filtered = [
      for (final e in widget.items())
        if (terms.every(
          (t) =>
              e.label.toLowerCase().contains(t) ||
              e.subtitle.toLowerCase().contains(t),
        ))
          e,
    ];
    _sel = 0; // so Enter in the search field picks the top match
  }

  String get _status {
    if (_statusOverride != null) return _statusOverride!;
    final n = _filtered.length;
    return '$n match(es)${widget.statusSuffix()}'
        '${n > maxRows ? ' (showing first $maxRows)' : ''}';
  }

  void _finish(String content, DbEntry? entry) {
    if (mounted) Navigator.of(context).pop(SearchResult(content, entry));
  }

  Future<void> _choose() async {
    if (_busy || _sel >= _filtered.length) return;
    final entry = _filtered[_sel];
    if (widget.returnEntryOnly) {
      _finish('', entry);
      return;
    }
    setState(() {
      _busy = true;
      _statusOverride = entry.remote ? 'Downloading ${entry.label}...' : null;
    });
    try {
      final content = await loadEntry(entry);
      _finish(content, entry);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _refresh();
      });
      await showInfo(context, 'AutoEQ', 'Could not load ${entry.label}:\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered.take(maxRows).toList();
    final controls = SearchDialogControls(
      _finish,
      () => setState(_refresh),
      (s) => setState(() => _statusOverride = s),
      context,
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      setState(
                        () => _sel = (_sel + 1).clamp(0, rows.length - 1),
                      ),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      setState(
                        () => _sel = (_sel - 1).clamp(0, rows.length - 1),
                      ),
                },
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                  onSubmitted: (_) => _choose(),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Palette.panel,
                    border: Border.all(color: Palette.line),
                  ),
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemExtent: widget.showSubtitle ? 44 : 34,
                    itemBuilder: (context, i) {
                      final e = rows[i];
                      final sel = i == _sel;
                      return InkWell(
                        onTap: () => setState(() => _sel = i),
                        onDoubleTap: () {
                          setState(() => _sel = i);
                          _choose();
                        },
                        child: Container(
                          color: sel ? Palette.accent : null,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          alignment: Alignment.centerLeft,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                e.label,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: sel ? Palette.chassis : Palette.ink,
                                ),
                              ),
                              if (widget.showSubtitle)
                                Text(
                                  e.subtitle,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: sel
                                        ? Palette.chassis
                                        : Palette.muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _status,
                style: const TextStyle(color: Palette.muted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (label, onPressed) in widget.extraButtons)
                    FilledButton(
                      onPressed: _busy ? null : () => onPressed(controls),
                      child: Text(label),
                    ),
                  FilledButton(
                    style: styleFor(ButtonKind.accent),
                    onPressed: _busy || rows.isEmpty ? null : _choose,
                    child: const Text('Select'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
