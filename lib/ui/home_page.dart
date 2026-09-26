import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/band.dart';
import '../core/dsp.dart';
import '../core/profile.dart';
import '../core/walkplay.dart';
import '../hid/hid.dart';
import '../state/eq_model.dart';
import 'autoeq_workflow.dart';
import 'dialogs.dart';
import 'eq_graph.dart';
import 'files.dart';
import 'theme.dart';

typedef _Action = (
  String label,
  VoidCallback onPressed,
  ButtonKind kind,
  String accel,
  SingleActivator? shortcut,
);

enum _FormFactor { compact, short, medium, expanded }

/// Layout class for a window size: phone portrait (compact), phone
/// landscape (short), tablet portrait / small window (medium), tablet
/// landscape / desktop (expanded).
_FormFactor _formFactorFor(Size s) {
  if (s.height < 520 && s.width > s.height && s.width >= 560) {
    return _FormFactor.short;
  }
  if (s.width >= 1100 && s.height >= 600) return _FormFactor.expanded;
  if (s.width >= 700) return _FormFactor.medium;
  return _FormFactor.compact;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> implements TaskHost {
  @override
  final model = EqModel();
  final _backend = HidBackend.create();
  late final _autoeq = AutoEqWorkflow(this);
  late final AppLifecycleListener _lifecycle;

  List<HidDeviceInfo> _devices = [];
  HidDeviceInfo? _selectedDevice;
  bool _devicesLoaded = false;

  final _vid = TextEditingController(text: '0x${hex4(walkplayVendorId)}');
  final _pid = TextEditingController();
  final _maxFilters = TextEditingController(text: '$defaultMaxFilters');
  final _slot = TextEditingController(text: '0');
  final _preamp = TextEditingController(text: '0');
  final _buffer = TextEditingController(text: '$defaultGlobalGainBuffer');
  final _edSlot = TextEditingController(text: '0');

  // Selected-band editor fields.
  final _freq = TextEditingController(text: '1000');
  final _gain = TextEditingController(text: '0');
  final _q = TextEditingController(text: '1.0');
  String _type = 'PK';
  bool _bwMode = false;
  int _fieldsRevision = -1;

  final _logScroll = ScrollController();
  int _logLength = 0;

  @override
  void initState() {
    super.initState();
    model.addListener(_onModelChanged);
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    _syncFromModel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final reason = _backend.unavailableReason;
      if (reason != null) model.log('ERROR: $reason');
      _refreshDevices();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    model.dispose();
    super.dispose();
  }

  // Sections that show model state rebuild through their own
  // ListenableBuilders; rebuilding the whole page on every change (one per
  // pointer move while dragging a band) is what made the graph lag.
  void _onModelChanged() => _syncFromModel();

  /// Push model state into the text fields and keep the log scrolled down.
  void _syncFromModel() {
    if (_preamp.text != model.preamp) _preamp.text = model.preamp;
    if (_fieldsRevision != model.fieldsRevision) {
      _fieldsRevision = model.fieldsRevision;
      _loadEditorFields();
    }
    if (model.logLines.length != _logLength) {
      _logLength = model.logLines.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  int get maxFilters => parseIntText(_maxFilters.text, defaultMaxFilters)!;

  // ------------------------------------------------------------------
  // Background tasks
  // ------------------------------------------------------------------

  @override
  Future<T?> runTask<T>(
    Future<T> Function() work, {
    (String, String)? busy,
    (String, String)? error,
  }) async {
    final close = busy != null ? showBusy(context, busy.$1, busy.$2) : null;
    try {
      return await work();
    } catch (e) {
      final text = errorText(e);
      model.log('ERROR: $text');
      close?.call();
      if (!mounted) return null;
      if (error != null) {
        await showInfo(context, error.$1, '${error.$2}:\n$text');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(text),
            backgroundColor: Palette.input,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return null;
    } finally {
      close?.call();
    }
  }

  // ------------------------------------------------------------------
  // Editor fields
  // ------------------------------------------------------------------

  void _loadEditorFields() {
    final f = model.primary;
    if (f == null) {
      _freq.text = _gain.text = _q.text = '';
      _type = 'PK';
      return;
    }
    _freq.text = f.freq.toString();
    _gain.text = f.gain.toString();
    _q.text = _bwMode ? qToBw(f.q).toStringAsFixed(3) : f.q.toString();
    _type = f.type;
  }

  /// Live-apply one edited field to every selected band.
  void _applyField(String field, String text) {
    if (field == 'type') {
      model.applyField('type', text);
      return;
    }
    var value = parseDoubleText(text);
    if (value == null || (field != 'gain' && value <= 0)) return;
    if (field == 'q' && _bwMode) {
      value = bwToQ(value);
      if (value == null) return;
    }
    model.applyField(field, value);
  }

  void _toggleBwMode(bool inBw) {
    setState(() => _bwMode = inBw);
    final val = parseDoubleText(_q.text);
    if (val == null || val <= 0) return;
    final converted = inBw ? qToBw(val) : bwToQ(val);
    // Only the display unit changes, not the band: don't live-apply.
    if (converted != null) _q.text = converted.toStringAsFixed(3);
  }

  // ------------------------------------------------------------------
  // Band operations
  // ------------------------------------------------------------------

  Future<void> _deleteAll() async {
    if (await askYesNo(context, 'Delete All Bands', 'Remove all EQ bands?')) {
      model.deleteAll();
    }
  }

  Future<void> _confirmDeleteBand(int index) async {
    if (index >= model.filters.length) return;
    final f = model.filters[index];
    if (await askYesNo(
      context,
      'Delete Band',
      'Delete band ${index + 1} (${f.freq.toStringAsFixed(1)} Hz)?',
    )) {
      model.removeBands([index]);
    }
  }

  // ------------------------------------------------------------------
  // Files
  // ------------------------------------------------------------------

  Future<bool> _saveProfile() async {
    if (model.filters.isEmpty) {
      await showInfo(context, 'No Filters', 'Add at least one EQ band first.');
      return false;
    }
    final content = formatProfile(
      parseDoubleText(model.preamp, 0)!,
      model.filters,
    );
    final path = await runTask(
      () => saveTextFile('Save Profile', 'eq_profile.txt', content),
      error: ('Save Error', 'Could not save the profile'),
    );
    if (path == null) return false;
    model.log('Profile saved to $path');
    return true;
  }

  Future<void> _loadProfile() async {
    final picked = await runTask(
      () => pickTextFile('Load Profile', const ['txt']),
      error: ('Load Error', 'Could not open the file'),
    );
    if (picked == null || !mounted) return;
    try {
      final profile = parseProfile(picked.content, source: picked.name);
      model.setFilters(profile.filters, profile.preamp);
      model.log('Loaded ${model.filters.length} filter(s) from ${picked.name}');
    } catch (e) {
      await showInfo(context, 'Load Error', errorText(e));
    }
  }

  // ------------------------------------------------------------------
  // Device
  // ------------------------------------------------------------------

  Future<void> _refreshDevices() async {
    setState(() {
      _selectedDevice = null; // the old pick may be unplugged by now
      _devicesLoaded = false;
    });
    if (_backend.unavailableReason != null) {
      setState(() => _devicesLoaded = true);
      return;
    }
    final devices = await runTask(
      () async => (await _backend.enumerate())
          .where((d) => d.vendorId == walkplayVendorId)
          .toList(),
    );
    if (!mounted) return;
    setState(() {
      _devices = devices ?? [];
      _devicesLoaded = true;
    });
  }

  void _selectDevice(HidDeviceInfo d) {
    setState(() => _selectedDevice = d);
    _vid.text = '0x${hex4(d.vendorId)}';
    _pid.text = '0x${hex4(d.productId)}';
  }

  /// Open by selection, else by VID/PID, else the first device with the VID.
  Future<HidDeviceInfo> _findDevice(int vid, int? pid) async {
    final candidates = (await _backend.enumerate())
        .where((d) => d.vendorId == vid && (pid == null || d.productId == pid))
        .toList();
    if (candidates.isEmpty) {
      throw StateError(
        'No HID device found with vendor id 0x${hex4(vid)}'
        '${pid != null ? ' and product id 0x${hex4(pid)}' : ''}. '
        'Refresh the device list, or set VID/PID manually.',
      );
    }
    if (candidates.length > 1 && pid == null) {
      final names = candidates
          .map((d) => '0x${hex4(d.productId)} (${d.product})')
          .join(', ');
      model.log(
        'Warning: multiple Walkplay devices/interfaces found ($names). '
        'Using the first one. Select a specific device in the list, or set PID.',
      );
    }
    return candidates.first;
  }

  /// Run [action] on the selected device; errors go to the log.
  Future<T?> _withDevice<T>(Future<T> Function(WalkplayDevice dev) action) {
    final vid = parseIntText(_vid.text, walkplayVendorId)!;
    final pid = parseIntText(_pid.text);
    final selected = _selectedDevice;
    return runTask(() async {
      final reason = _backend.unavailableReason;
      if (reason != null) throw StateError(reason);
      final info = selected ?? await _findDevice(vid, pid);
      final conn = await _backend.open(info);
      try {
        return await action(WalkplayDevice(conn, model.log));
      } finally {
        await conn.close();
      }
    });
  }

  void _getSlot() => _withDevice((dev) => dev.getCurrentSlot());

  void _enable() {
    final slot = parseIntText(_edSlot.text, 0)!;
    _withDevice((dev) async {
      await dev.enablePeq(true, slot);
      model.log('PEQ enabled on slot $slot');
    });
  }

  void _disable() => _withDevice((dev) async {
    await dev.enablePeq(false);
    model.log('PEQ disabled');
  });

  Future<void> _loadFromDevice() async {
    if (!await askYesNo(
      context,
      'Load EQ from Device',
      'Load EQ from device? This will replace all current filters.',
    )) {
      return;
    }
    final max = maxFilters;
    final buffer = parseDoubleText(_buffer.text, defaultGlobalGainBuffer)!;
    final result = await _withDevice(
      (dev) async =>
          dev.pull(max, slotHint: await dev.getCurrentSlot(), bufferDb: buffer),
    );
    if (result != null) model.setFilters(result.filters, result.preamp);
  }

  /// Push the EQ; true after a successful push.
  Future<bool> _push() async {
    if (model.filters.isEmpty) {
      await showInfo(context, 'No Filters', 'Add at least one EQ band first.');
      return false;
    }
    final slot = parseIntText(_slot.text, 0)!;
    final preamp = parseDoubleText(model.preamp, 0)!;
    final buffer = parseDoubleText(_buffer.text, defaultGlobalGainBuffer)!;
    final max = maxFilters;
    final count = model.filters.length;

    if (count > max &&
        await askChoice<String>(
              context,
              'Too Many Bands',
              'You have $count EQ bands, but the device is set to support '
                  'only $max filter slot(s) (see \'Max filters\').\n\n'
                  'Only the first $max band(s) would be written to the device '
                  '— the rest would be silently dropped.\n\n'
                  'Reduce your EQ to $max band(s), correct \'Max filters\' to '
                  'match your device, or push anyway (will break your EQ).',
              [
                ('Cancel', null, ButtonKind.normal),
                ('Push Anyway', 'push', ButtonKind.danger),
              ],
              focus: 'Cancel',
            ) !=
            'push') {
      return false;
    }

    final filters = padForPush(model.filters, max);
    final ok = await _withDevice((dev) async {
      await dev.push(slot, preamp, filters, bufferDb: buffer);
      await dev.enablePeq(true, slot);
      model.log('EQ pushed to device on slot $slot (${filters.length} slots)');
      return true;
    });
    return ok == true;
  }

  // ------------------------------------------------------------------
  // Quit
  // ------------------------------------------------------------------

  bool _quitDialogOpen = false;

  Future<bool> _confirmQuit() async {
    if (_quitDialogOpen) return false;
    _quitDialogOpen = true;
    try {
      final choice = await askChoice<String>(
        context,
        'Quit',
        'Do you really want to leave this application?',
        [
          ('Quit', 'quit', ButtonKind.danger),
          ('Cancel', null, ButtonKind.normal),
          ('Push to device and quit', 'push', ButtonKind.normal),
          ('Save to file and quit', 'save', ButtonKind.normal),
        ],
        enter: 'quit',
        focus: 'Quit',
      );
      return switch (choice) {
        'quit' => true,
        'push' => await _push(),
        'save' => await _saveProfile(),
        _ => false,
      };
    } finally {
      _quitDialogOpen = false;
    }
  }

  Future<AppExitResponse> _onExitRequested() async =>
      await _confirmQuit() ? AppExitResponse.exit : AppExitResponse.cancel;

  // ------------------------------------------------------------------
  // Layout
  // ------------------------------------------------------------------

  List<_Action> get _actions => [
    (
      'Add Band',
      () => model.addBand(),
      ButtonKind.normal,
      'Ctrl+B',
      const SingleActivator(LogicalKeyboardKey.keyB, control: true),
    ),
    (
      'Delete Band',
      model.deleteSelected,
      ButtonKind.danger,
      'Ctrl+D',
      const SingleActivator(LogicalKeyboardKey.keyD, control: true),
    ),
    (
      'Delete All',
      _deleteAll,
      ButtonKind.danger,
      'Ctrl+Shift+D',
      const SingleActivator(
        LogicalKeyboardKey.keyD,
        control: true,
        shift: true,
      ),
    ),
    (
      'Load EQ from Device',
      _loadFromDevice,
      ButtonKind.normal,
      'Ctrl+E',
      const SingleActivator(LogicalKeyboardKey.keyE, control: true),
    ),
    (
      'Save Profile to File',
      _saveProfile,
      ButtonKind.normal,
      'Ctrl+S',
      const SingleActivator(LogicalKeyboardKey.keyS, control: true),
    ),
    (
      'Load Profile from File',
      _loadProfile,
      ButtonKind.normal,
      'Ctrl+O',
      const SingleActivator(LogicalKeyboardKey.keyO, control: true),
    ),
    (
      'Compute AutoEQ',
      _autoeq.compute,
      ButtonKind.normal,
      'Ctrl+Shift+A',
      const SingleActivator(
        LogicalKeyboardKey.keyA,
        control: true,
        shift: true,
      ),
    ),
    (
      'Load Pre-computed AutoEQ',
      _autoeq.loadPrecomputed,
      ButtonKind.normal,
      'Ctrl+Shift+L',
      const SingleActivator(
        LogicalKeyboardKey.keyL,
        control: true,
        shift: true,
      ),
    ),
    (
      'Push EQ to Device',
      _push,
      ButtonKind.accent,
      'Ctrl+P',
      const SingleActivator(LogicalKeyboardKey.keyP, control: true),
    ),
  ];

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    for (final a in _actions)
      if (a.$5 != null) a.$5!: a.$2,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): model.undo,
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): model.redo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
        model.redo,
    const SingleActivator(LogicalKeyboardKey.f5): _refreshDevices,
    const SingleActivator(LogicalKeyboardKey.keyG, control: true): _getSlot,
    const SingleActivator(LogicalKeyboardKey.keyE, control: true, shift: true):
        _enable,
    const SingleActivator(LogicalKeyboardKey.keyX, control: true, shift: true):
        _disable,
  };

  @override
  Widget build(BuildContext context) {
    final form = _formFactorFor(MediaQuery.sizeOf(context));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _confirmQuit()) {
          await SystemNavigator.pop();
        }
      },
      child: CallbackShortcuts(
        bindings: _shortcuts,
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              toolbarHeight: form == _FormFactor.short ? 44 : null,
              title: const Text('Walkplay PEQ Loader'),
              actions: [
                ListenableBuilder(
                  listenable: model,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Undo (Ctrl+Z)',
                        icon: const Icon(Icons.undo),
                        onPressed: model.canUndo ? model.undo : null,
                      ),
                      IconButton(
                        tooltip: 'Redo (Ctrl+Y)',
                        icon: const Icon(Icons.redo),
                        onPressed: model.canRedo ? model.redo : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, c) => switch (form) {
                  _FormFactor.compact => _compactLayout(c),
                  _FormFactor.short => _shortLayout(c),
                  _FormFactor.medium => _mediumLayout(c),
                  _FormFactor.expanded => _expandedLayout(c),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _touch => const {
    TargetPlatform.android,
    TargetPlatform.iOS,
  }.contains(Theme.of(context).platform);

  double get _rowExtent => _touch ? 40 : 30;

  static const _gap = SizedBox(height: 8, width: 8);

  // The graph stays a stable, separately repainted subtree: it listens to
  // the model itself, so no layout below rebuilds while a band is dragged.
  late final Widget _graphView = Container(
    decoration: BoxDecoration(border: Border.all(color: Palette.line)),
    child: EqGraph(model: model, onDeleteRequest: _confirmDeleteBand),
  );

  /// Phone portrait: graph pinned on top, everything else scrolls below it
  /// (so dragging bands never fights the scroll view).
  Widget _compactLayout(BoxConstraints c) {
    final graphHeight = (c.maxHeight * 0.36).clamp(200.0, 360.0);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: SizedBox(height: graphHeight, child: _graphView),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              _filterList(4.5),
              _gap,
              _editor(),
              _gap,
              _actionsGrid(c.maxWidth >= 480 ? 3 : 2),
              _gap,
              _eqSettings(),
              _gap,
              _peqEnable(),
              _gap,
              _deviceSection(),
              _gap,
              _logSection(160),
            ],
          ),
        ),
      ],
    );
  }

  /// Phone landscape: graph uses the full height on the left, controls
  /// scroll on the right.
  Widget _shortLayout(BoxConstraints c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 0, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 11,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _graphView,
            ),
          ),
          Expanded(
            flex: 9,
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                _filterList(3.5),
                _gap,
                _editor(),
                _gap,
                _actionsGrid(2),
                _gap,
                _eqSettings(),
                _gap,
                _peqEnable(),
                _gap,
                _deviceSection(),
                _gap,
                _logSection(140),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tablet portrait / small desktop window: graph on top, two columns of
  /// panels below.
  Widget _mediumLayout(BoxConstraints c) {
    final graphHeight = (c.maxHeight * 0.42).clamp(240.0, 520.0);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: SizedBox(height: graphHeight, child: _graphView),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _filterList(5.5),
                      _gap,
                      _editor(),
                      _gap,
                      _eqSettings(),
                      _gap,
                      _peqEnable(),
                    ],
                  ),
                ),
                _gap,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _actionsGrid(2),
                      _gap,
                      _deviceSection(),
                      _gap,
                      _logSection(180),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Tablet landscape / desktop: graph and panels on the left, actions rail
  /// on the right.
  Widget _expandedLayout(BoxConstraints c) {
    final listWidth = (c.maxWidth * 0.28).clamp(300.0, 420.0);
    final roomy = c.maxWidth >= 1500;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(flex: 5, child: _graphView),
                _gap,
                Expanded(
                  flex: 6,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: listWidth, child: _filterList(6.5)),
                            _gap,
                            Expanded(child: _editor()),
                          ],
                        ),
                        _gap,
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _eqSettings()),
                            _gap,
                            Expanded(child: _peqEnable()),
                          ],
                        ),
                        _gap,
                        if (roomy)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _deviceSection()),
                              _gap,
                              Expanded(child: _logSection(146)),
                            ],
                          )
                        else ...[
                          _deviceSection(),
                          _gap,
                          _logSection(150),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          _gap,
          SizedBox(width: 240, child: _actionsRail()),
        ],
      ),
    );
  }

  // ---- sections --------------------------------------------------------

  Widget _actionsRail() => SingleChildScrollView(
    child: Section(
      title: 'Actions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final a in _actions)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: SizedBox(
                height: _touch ? 52 : 46,
                child: _actionButton(a),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _actionsGrid(int columns) => Section(
    title: 'Actions',
    child: LayoutBuilder(
      builder: (context, c) {
        const spacing = 6.0;
        final w = (c.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final a in _actions)
              SizedBox(
                width: w,
                height: _touch ? 48 : 42,
                child: _actionButton(a),
              ),
          ],
        );
      },
    ),
  );

  Widget _actionButton(_Action a) => Tooltip(
    message: a.$4,
    waitDuration: const Duration(milliseconds: 600),
    child: FilledButton(
      style: styleFor(a.$3),
      onPressed: a.$2,
      child: Text(
        a.$1,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );

  /// Band list, [rows] rows tall.
  Widget _filterList(double rows) {
    final extent = _rowExtent;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final highlighted = model.selection;
        return Section(
          title: 'Filters',
          trailing: Text(
            '${model.filters.length} band(s)',
            style: const TextStyle(color: Palette.muted, fontSize: 11),
          ),
          child: Container(
            height: extent * rows,
            decoration: BoxDecoration(
              color: Palette.panel,
              border: Border.all(color: Palette.line),
            ),
            child: model.filters.isEmpty
                ? const Center(
                    child: Text(
                      'No bands. Tap the graph or "Add Band".',
                      style: TextStyle(color: Palette.muted),
                    ),
                  )
                : ListView.builder(
                    itemCount: model.filters.length,
                    itemExtent: extent,
                    itemBuilder: (context, i) {
                      final f = model.filters[i];
                      final sel = highlighted.contains(i);
                      return InkWell(
                        onTap: () {
                          final kb = HardwareKeyboard.instance;
                          if (kb.isControlPressed) {
                            model.toggleSelect(i);
                          } else if (kb.isShiftPressed) {
                            model.rangeSelect(i);
                          } else {
                            model.select(i);
                          }
                        },
                        onLongPress: () => model.toggleSelect(i),
                        child: Container(
                          color: sel ? Palette.accent : null,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${i + 1}: ${f.freq.toStringAsFixed(1)} Hz  '
                            '${f.gain.toStringAsFixed(1)} dB  '
                            'Q ${f.q.toStringAsFixed(2)}  ${f.type}',
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: TextStyle(
                              fontFamily: monoFont,
                              fontFamilyFallback: monoFallback,
                              fontSize: 12.5,
                              color: sel ? Palette.chassis : Palette.ink,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }

  Widget _editor() => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final enabled = model.primary != null;
      final count = model.effectiveSelection.length;
      return Section(
        title: count > 1 ? 'Selected Filters ($count)' : 'Selected Filter',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NumberField(
              label: 'Frequency (Hz)',
              controller: _freq,
              enabled: enabled,
              step: 1,
              decimals: 0,
              min: 10,
              max: 30000,
              onChanged: (t) => _applyField('freq', t),
            ),
            _NumberField(
              label: 'Gain (dB)',
              controller: _gain,
              enabled: enabled,
              step: 0.1,
              decimals: 1,
              min: -30,
              max: 30,
              onChanged: (t) => _applyField('gain', t),
            ),
            _NumberField(
              label: _bwMode ? 'Bandwidth (oct)' : 'Q',
              controller: _q,
              enabled: enabled,
              step: 0.1,
              decimals: 1,
              min: 0.1,
              max: 100,
              onChanged: (t) => _applyField('q', t),
            ),
            _LabeledRow(
              label: 'Type',
              child: InputDecorator(
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 8),
                ),
                isEmpty: false,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _type,
                    isExpanded: true,
                    isDense: !_touch,
                    items: [
                      for (final t in filterTypes)
                        DropdownMenuItem(value: t, child: Text(t)),
                    ],
                    onChanged: enabled
                        ? (t) {
                            if (t == null) return;
                            _type = t;
                            _applyField('type', t);
                          }
                        : null,
                  ),
                ),
              ),
            ),
            Row(
              children: [
                Checkbox(
                  value: _bwMode,
                  onChanged: (v) => _toggleBwMode(v ?? false),
                ),
                const Flexible(child: Text('Show Q as Bandwidth (oct)')),
              ],
            ),
          ],
        ),
      );
    },
  );

  Widget _eqSettings() => Section(
    title: 'EQ',
    child: Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        _SmallField(label: 'Slot', controller: _slot, width: 70, intOnly: true),
        _SmallField(
          label: 'Preamp (dB)',
          controller: _preamp,
          width: 110,
          onChanged: (t) => model.setPreampText(t),
        ),
        _SmallField(label: 'Buffer (dB)', controller: _buffer, width: 110),
      ],
    ),
  );

  Widget _peqEnable() => Section(
    title: 'PEQ Enable / Disable',
    child: Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _SmallField(
          label: 'Slot',
          controller: _edSlot,
          width: 70,
          intOnly: true,
        ),
        Tooltip(
          message: 'Ctrl+Shift+E',
          child: FilledButton(
            style: styleFor(ButtonKind.accent),
            onPressed: _enable,
            child: const Text('Enable PEQ'),
          ),
        ),
        Tooltip(
          message: 'Ctrl+Shift+X',
          child: FilledButton(
            style: styleFor(ButtonKind.danger),
            onPressed: _disable,
            child: const Text('Disable PEQ'),
          ),
        ),
      ],
    ),
  );

  Widget _deviceSection() {
    Widget list;
    if (!_devicesLoaded) {
      list = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else if (_devices.isEmpty) {
      list = Center(
        child: Text(
          _backend.unavailableReason ?? '(no Walkplay-vendor devices found)',
          style: const TextStyle(color: Palette.muted),
          textAlign: TextAlign.center,
        ),
      );
    } else {
      list = ListView(
        children: [
          for (final d in _devices)
            InkWell(
              onTap: () => _selectDevice(d),
              child: Container(
                color: identical(d, _selectedDevice) ? Palette.accent : null,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  'pid=0x${hex4(d.productId)} iface=${d.interfaceNumber}  '
                  '${d.product}',
                  style: TextStyle(
                    color: identical(d, _selectedDevice)
                        ? Palette.chassis
                        : Palette.ink,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return Section(
      title: 'Device',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  height: 100,
                  decoration: BoxDecoration(
                    color: Palette.panel,
                    border: Border.all(color: Palette.line),
                  ),
                  child: list,
                ),
              ),
              const SizedBox(width: 8),
              IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Tooltip(
                      message: 'F5',
                      child: FilledButton(
                        onPressed: _refreshDevices,
                        child: const Text('Refresh List'),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Tooltip(
                      message: 'Ctrl+G',
                      child: FilledButton(
                        onPressed: _getSlot,
                        child: const Text('Get Slot / Version'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _SmallField(label: 'VID (hex)', controller: _vid, width: 100),
              _SmallField(
                label: 'PID (hex, optional)',
                controller: _pid,
                width: 140,
              ),
              _SmallField(
                label: 'Max filters',
                controller: _maxFilters,
                width: 90,
                intOnly: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _logSection(double height) => Section(
    title: 'Log',
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Copy log',
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          icon: const Icon(Icons.copy, color: Palette.muted),
          onPressed: () =>
              Clipboard.setData(ClipboardData(text: model.logLines.join('\n'))),
        ),
      ],
    ),
    child: Container(
      height: height,
      decoration: BoxDecoration(border: Border.all(color: Palette.line)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: ListenableBuilder(
        listenable: model,
        builder: (context, _) => SelectionArea(
          child: ListView.builder(
            controller: _logScroll,
            itemCount: model.logLines.length,
            itemBuilder: (context, i) => Text(
              model.logLines[i],
              style: const TextStyle(
                fontFamily: monoFont,
                fontFamilyFallback: monoFallback,
                fontSize: 12,
                color: Palette.accent,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

String errorText(Object e) => switch (e) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  PlatformException(:final code, :final message) => message ?? code,
  FileSystemException(:final message, :final path, :final osError) =>
    '$message${path != null ? ' ($path)' : ''}'
        '${osError != null ? ': ${osError.message}' : ''}',
  SocketException(:final message) => 'Network error: $message',
  _ => e.toString(),
};

// ---------------------------------------------------------------------------
// Small field widgets
// ---------------------------------------------------------------------------

class _LabeledRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _LabeledRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(width: 120, child: Text(label)),
        Expanded(child: child),
      ],
    ),
  );
}

/// A number entry with -/+ steppers (the desktop app's Spinbox).
class _NumberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool enabled;
  final double step, min, max;
  final int decimals;
  final ValueChanged<String> onChanged;

  const _NumberField({
    required this.label,
    required this.controller,
    required this.enabled,
    required this.step,
    required this.decimals,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  void _step(int dir) {
    final current = parseDoubleText(controller.text) ?? min;
    final next = (current + dir * step).clamp(min, max);
    controller.text = next.toStringAsFixed(decimals);
    onChanged(controller.text);
  }

  @override
  Widget build(BuildContext context) => _LabeledRow(
    label: label,
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            onChanged: onChanged,
          ),
        ),
        _StepButton(
          icon: Icons.remove,
          onPressed: enabled ? () => _step(-1) : null,
        ),
        _StepButton(
          icon: Icons.add,
          onPressed: enabled ? () => _step(1) : null,
        ),
      ],
    ),
  );
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  const _StepButton({required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: SizedBox(
      width: 36,
      height: 36,
      child: IconButton.filledTonal(
        padding: EdgeInsets.zero,
        iconSize: 18,
        style: IconButton.styleFrom(
          backgroundColor: Palette.input,
          foregroundColor: Palette.ink,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    ),
  );
}

class _SmallField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final double width;
  final bool intOnly;
  final ValueChanged<String>? onChanged;

  const _SmallField({
    required this.label,
    required this.controller,
    required this.width,
    this.intOnly = false,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: TextField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
      keyboardType: intOnly
          ? TextInputType.number
          : const TextInputType.numberWithOptions(decimal: true, signed: true),
      inputFormatters: intOnly
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      onChanged: onChanged,
    ),
  );
}
