import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_info.dart';
import '../../state/eq_model.dart';
import '../theme.dart';
import '../widgets/section.dart';

/// Diagnostics for bug reports, and the log, kept scrolled to the newest
/// line.
class LogPage extends StatefulWidget {
  final EqModel model;

  /// Why USB HID doesn't work here; null when it does.
  final String? hidUnavailableReason;

  const LogPage({super.key, required this.model, this.hidUnavailableReason});

  static String get platformName => kIsWeb
      ? 'Web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.android => 'Android',
          TargetPlatform.linux => 'Linux',
          TargetPlatform.windows => 'Windows',
          TargetPlatform.macOS => 'macOS',
          TargetPlatform.iOS => 'iOS',
          TargetPlatform.fuchsia => 'Fuchsia',
        };

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  EqModel get _model => widget.model;
  final _scroll = ScrollController();
  late int _revision = _model.logRevision;

  String get _diagnostics =>
      '$appName $appVersion · ${LogPage.platformName} · '
      'USB HID: ${widget.hidUnavailableReason ?? 'available'}';

  @override
  void initState() {
    super.initState();
    _model.addListener(_changed);
    _scrollToEnd();
  }

  @override
  void dispose() {
    _model.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (_model.logRevision == _revision) return;
    setState(() => _revision = _model.logRevision);
    _scrollToEnd();
  }

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  Future<void> _copy(String what, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$what copied')));
  }

  Widget _copyButton(String what, String Function() text) => IconButton(
    tooltip: 'Copy ${what.toLowerCase()}',
    visualDensity: VisualDensity.compact,
    iconSize: 16,
    icon: const Icon(Icons.copy, color: Palette.muted),
    onPressed: () => _copy(what, text()),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Log')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Section(
                title: 'Diagnostics',
                trailing: _copyButton('Diagnostics', () => _diagnostics),
                child: SelectableText(
                  _diagnostics,
                  style: monoStyle(size: 12, color: Palette.ink),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Section(
                  title: 'Log',
                  expand: true,
                  trailing: _copyButton(
                    'Log',
                    () => _model.logLines.join('\n'),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Palette.line),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: _model.logLines.isEmpty
                        ? const Center(
                            child: Text(
                              'Nothing logged yet.',
                              style: TextStyle(color: Palette.muted),
                            ),
                          )
                        : SelectionArea(
                            child: ListView.builder(
                              controller: _scroll,
                              itemCount: _model.logLines.length,
                              itemBuilder: (context, i) => Text(
                                _model.logLines[i],
                                style: monoStyle(
                                  size: 12,
                                  color: Palette.accent,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
