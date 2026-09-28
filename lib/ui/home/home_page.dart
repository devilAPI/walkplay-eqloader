import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../hid/hid.dart';
import '../../state/device_controller.dart';
import '../../state/eq_model.dart';
import '../../state/profile_library.dart';
import '../../state/settings.dart';
import '../eq_graph.dart';
import '../settings/settings_page.dart';
import '../task_host.dart';
import '../theme.dart';
import '../widgets/select_builder.dart';
import 'home_controller.dart';
import 'layouts.dart';

/// The editor: owns the EQ and the device connection, wires shortcuts and
/// the quit confirmation, and lays the panels out for the window size.
class HomePage extends StatefulWidget {
  final Settings settings;
  final ProfileLibrary library;
  final HidBackend? backend;

  const HomePage({
    super.key,
    required this.settings,
    required this.library,
    this.backend,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TaskRunner<HomePage> {
  @override
  final model = EqModel();

  @override
  Settings get settings => widget.settings;

  late final _device = DeviceController(
    widget.backend ?? HidBackend.create(),
    model.log,
  );
  late final _home = HomeController(
    this,
    device: _device,
    library: widget.library,
  );
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final reason = _device.unavailableReason;
      if (reason != null) model.log('ERROR: $reason');
      _home.deviceCommands.refresh();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _device.dispose();
    model.dispose();
    super.dispose();
  }

  Future<AppExitResponse> _onExitRequested() async =>
      await _home.confirmQuit() ? AppExitResponse.exit : AppExitResponse.cancel;

  void _openSettings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsPage(
        settings: settings,
        model: model,
        hidUnavailableReason: _device.unavailableReason,
      ),
    ),
  );

  // The graph stays a stable, separately repainted subtree: it listens to
  // the model itself, so no layout below rebuilds while a band is dragged.
  late final Widget _graph = Container(
    decoration: BoxDecoration(border: Border.all(color: Palette.line)),
    child: EqGraph(
      model: model,
      settings: settings,
      onDeleteRequest: _home.confirmDeleteBand,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final form = FormFactor.of(MediaQuery.sizeOf(context));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _home.confirmQuit()) {
          await SystemNavigator.pop();
        }
      },
      child: CallbackShortcuts(
        bindings: _home.shortcuts,
        child: Focus(
          autofocus: true,
          child: HomeScope(
            home: _home,
            child: Scaffold(
              appBar: _appBar(form),
              body: SafeArea(
                child: LayoutBuilder(
                  builder: (context, c) => buildLayout(form, _graph, c),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  AppBar _appBar(FormFactor form) => AppBar(
    toolbarHeight: form == FormFactor.short ? 44 : null,
    title: const FittedBox(
      fit: BoxFit.scaleDown,
      child: Text('Walkplay PEQ Loader'),
    ),
    actions: [
      // Phones show one tab at a time; keep the device transfers always
      // reachable.
      if (form.isPhone) ...[
        IconButton(
          tooltip: _home.loadFromDevice.label,
          icon: const Icon(Icons.download),
          onPressed: _home.loadFromDevice.onPressed,
        ),
        IconButton(
          tooltip: _home.push.label,
          icon: const Icon(Icons.upload, color: Palette.accent),
          onPressed: _home.push.onPressed,
        ),
      ],
      SelectBuilder(
        model,
        () => (model.canUndo, model.canRedo),
        (context) => Row(
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
      // Phones have Settings in the tab bar.
      if (!form.isPhone)
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: _openSettings,
        ),
      const SizedBox(width: 4),
    ],
  );
}
