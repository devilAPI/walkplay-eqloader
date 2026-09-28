import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/device_controller.dart';
import '../../state/eq_model.dart';
import '../../state/profile_library.dart';
import '../../state/settings.dart';
import '../commands/autoeq_workflow.dart';
import '../commands/device_commands.dart';
import '../commands/file_commands.dart';
import '../commands/library_commands.dart';
import '../dialogs.dart';
import '../task_host.dart';
import '../theme.dart';

/// A button-worthy command with its keyboard shortcut.
class AppAction {
  final String label;
  final VoidCallback onPressed;
  final ButtonKind kind;
  final IconData? icon;
  final SingleActivator? shortcut;

  const AppAction(
    this.label,
    this.onPressed, {
    this.kind = ButtonKind.normal,
    this.icon,
    this.shortcut,
  });

  /// "Ctrl+Shift+D" etc., for tooltips.
  String get shortcutLabel {
    final s = shortcut;
    if (s == null) return '';
    return [
      if (s.control) 'Ctrl',
      if (s.shift) 'Shift',
      if (s.alt) 'Alt',
      s.trigger.keyLabel,
    ].join('+');
  }
}

/// Everything the home page's panels use: the state objects, the command
/// groups, and the actions/shortcuts built from them.
class HomeController {
  final TaskHost host;
  final DeviceController device;
  final ProfileLibrary library;

  HomeController(this.host, {required this.device, required this.library});

  EqModel get model => host.model;
  Settings get settings => host.settings;

  late final deviceCommands = DeviceCommands(host, device, library);
  late final libraryCommands = LibraryCommands(host, library);
  late final fileCommands = FileCommands(host, library);
  late final autoeq = AutoEqWorkflow(host);

  // ---- band commands -----------------------------------------------------

  Future<void> deleteAll() async {
    if (await askYesNo(
      host.context,
      'Delete All Bands',
      'Remove all EQ bands?',
    )) {
      model.deleteAll();
    }
  }

  Future<void> confirmDeleteBand(int index) async {
    if (index >= model.filters.length) return;
    final f = model.filters[index];
    if (await askYesNo(
      host.context,
      'Delete Band',
      'Delete band ${index + 1} (${f.freq.toStringAsFixed(1)} Hz)?',
    )) {
      model.removeBands([index]);
    }
  }

  // ---- quit --------------------------------------------------------------

  bool _quitDialogOpen = false;

  Future<bool> confirmQuit() async {
    if (_quitDialogOpen) return false;
    _quitDialogOpen = true;
    try {
      final choice = await askChoice<String>(
        host.context,
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
        'push' => await deviceCommands.push(confirm: false),
        'save' => await fileCommands.save(),
        _ => false,
      };
    } finally {
      _quitDialogOpen = false;
    }
  }

  // ---- actions -----------------------------------------------------------

  late final addBand = AppAction(
    'Add Band',
    () => model.addBand(),
    icon: Icons.add,
    shortcut: const SingleActivator(LogicalKeyboardKey.keyB, control: true),
  );
  late final deleteBand = AppAction(
    'Delete Band',
    model.deleteSelected,
    kind: ButtonKind.danger,
    icon: Icons.remove_circle_outline,
    shortcut: const SingleActivator(LogicalKeyboardKey.keyD, control: true),
  );
  late final deleteAllBands = AppAction(
    'Delete All',
    deleteAll,
    kind: ButtonKind.danger,
    icon: Icons.delete_sweep_outlined,
    shortcut: const SingleActivator(
      LogicalKeyboardKey.keyD,
      control: true,
      shift: true,
    ),
  );
  late final loadFromDevice = AppAction(
    'Load EQ from Device',
    deviceCommands.loadFromDevice,
    icon: Icons.download,
    shortcut: const SingleActivator(LogicalKeyboardKey.keyE, control: true),
  );
  late final push = AppAction(
    'Push EQ to Device',
    deviceCommands.push,
    kind: ButtonKind.accent,
    icon: Icons.upload,
    shortcut: const SingleActivator(LogicalKeyboardKey.keyP, control: true),
  );
  late final saveFile = AppAction(
    'Save Profile to File',
    fileCommands.save,
    shortcut: const SingleActivator(LogicalKeyboardKey.keyS, control: true),
  );
  late final loadFile = AppAction(
    'Load Profile from File',
    fileCommands.load,
    shortcut: const SingleActivator(LogicalKeyboardKey.keyO, control: true),
  );
  late final computeAutoEq = AppAction(
    'Compute AutoEQ',
    autoeq.compute,
    shortcut: const SingleActivator(
      LogicalKeyboardKey.keyA,
      control: true,
      shift: true,
    ),
  );
  late final loadPrecomputed = AppAction(
    'Load Pre-computed AutoEQ',
    autoeq.loadPrecomputed,
    shortcut: const SingleActivator(
      LogicalKeyboardKey.keyL,
      control: true,
      shift: true,
    ),
  );
  late final saveToLibrary = AppAction(
    'Save to Library',
    libraryCommands.saveCurrent,
    icon: Icons.bookmark_add_outlined,
    shortcut: const SingleActivator(
      LogicalKeyboardKey.keyS,
      control: true,
      shift: true,
    ),
  );
  late final importToLibrary = AppAction(
    'Import File to Library',
    libraryCommands.importFile,
    icon: Icons.file_open_outlined,
  );

  List<AppAction> get bandActions => [addBand, deleteBand, deleteAllBands];

  List<AppAction> get fileActions => [
    saveFile,
    loadFile,
    computeAutoEq,
    loadPrecomputed,
  ];

  /// The desktop actions rail / grid, in order.
  List<AppAction> get allActions => [
    ...bandActions,
    loadFromDevice,
    ...fileActions,
    push,
  ];

  Map<ShortcutActivator, VoidCallback> get shortcuts => {
    for (final a in [...allActions, saveToLibrary])
      if (a.shortcut != null) a.shortcut!: a.onPressed,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): model.undo,
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): model.redo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
        model.redo,
    const SingleActivator(LogicalKeyboardKey.f5): deviceCommands.refresh,
    const SingleActivator(LogicalKeyboardKey.keyG, control: true):
        deviceCommands.getSlot,
    const SingleActivator(LogicalKeyboardKey.keyE, control: true, shift: true):
        deviceCommands.enable,
    const SingleActivator(LogicalKeyboardKey.keyX, control: true, shift: true):
        deviceCommands.disable,
  };
}

/// Hands the [HomeController] to the panels below the home page.
class HomeScope extends InheritedWidget {
  final HomeController home;
  const HomeScope({super.key, required this.home, required super.child});

  /// The controller never changes, so panels don't need to depend on it.
  static HomeController of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HomeScope>()!.home;

  @override
  bool updateShouldNotify(HomeScope old) => old.home != home;
}
