import 'package:flutter/material.dart';

import '../settings/settings_page.dart';
import '../theme.dart';
import '../widgets/section.dart';
import 'home_controller.dart';
import 'panels/action_buttons.dart';
import 'panels/band_editor_panel.dart';
import 'panels/band_list_panel.dart';
import 'panels/device_panel.dart';
import 'panels/library_panel.dart';
import 'panels/push_panels.dart';

enum FormFactor {
  /// Phone portrait.
  compact,

  /// Phone landscape.
  short,

  /// Tablet portrait / small window.
  medium,

  /// Tablet landscape / desktop.
  expanded;

  static FormFactor of(Size s) {
    if (s.height < 520 && s.width > s.height && s.width >= 560) return short;
    if (s.width >= 1100 && s.height >= 600) return expanded;
    if (s.width >= 700) return medium;
    return compact;
  }

  bool get isPhone => this == compact || this == short;
}

const _gap = SizedBox(height: 8, width: 8);

/// The page body for [form]. [graph] is built once by the page and reused,
/// so layout changes never rebuild it.
Widget buildLayout(FormFactor form, Widget graph, BoxConstraints c) =>
    switch (form) {
      FormFactor.compact || FormFactor.short => PhoneLayout(
        graph: graph,
        landscape: form == FormFactor.short,
        constraints: c,
      ),
      FormFactor.medium => _MediumLayout(graph: graph, constraints: c),
      FormFactor.expanded => _ExpandedLayout(graph: graph, constraints: c),
    };

// ---- phones ---------------------------------------------------------------
//
// Phones get the graph plus one tab of controls at a time instead of every
// desktop panel stacked into one long scroll. Portrait and landscape are the
// same widget, so the open tab survives rotating.

class PhoneLayout extends StatefulWidget {
  final Widget graph;
  final bool landscape;
  final BoxConstraints constraints;

  const PhoneLayout({
    super.key,
    required this.graph,
    required this.landscape,
    required this.constraints,
  });

  @override
  State<PhoneLayout> createState() => _PhoneLayoutState();
}

class _PhoneLayoutState extends State<PhoneLayout> {
  int _tab = 0;

  static const _tabs = [
    (Icons.tune, 'EQ'),
    (Icons.usb, 'Device'),
    (Icons.library_music_outlined, 'Profiles'),
    (Icons.settings_outlined, 'Settings'),
  ];

  static const _settingsTab = 3;

  /// Settings has nothing to do with the curve, so it gets the whole screen.
  bool get _showGraph => _tab != _settingsTab;

  void _select(int i) => setState(() => _tab = i);

  Widget _tabView(int columns) {
    final home = HomeScope.of(context);
    if (_tab == _settingsTab) {
      return SettingsView(
        settings: home.settings,
        model: home.model,
        hidUnavailableReason: home.device.unavailableReason,
      );
    }
    return ListView(
      key: PageStorageKey(_tab),
      padding: const EdgeInsets.all(8),
      children: switch (_tab) {
        0 => const [
          BandListPanel(rows: 3.5, headerActions: true),
          _gap,
          BandEditorPanel(),
          _gap,
          Section(
            title: 'Preamp',
            child: Align(alignment: Alignment.centerLeft, child: PreampField()),
          ),
        ],
        1 => [
          ButtonGrid(
            columns: columns,
            actions: [home.push, home.loadFromDevice],
          ),
          _gap,
          const Section(
            title: 'Push Settings',
            child: Align(
              alignment: Alignment.centerLeft,
              child: PushSlotField(),
            ),
          ),
          _gap,
          const PeqEnablePanel(),
          _gap,
          const DevicePanel(),
        ],
        _ => [
          const LibraryPanel(rows: 4.5),
          _gap,
          Section(
            title: 'Files & AutoEQ',
            child: ButtonGrid(columns: columns, actions: home.fileActions),
          ),
        ],
      },
    );
  }

  @override
  Widget build(BuildContext context) =>
      widget.landscape ? _landscape() : _portrait();

  /// Graph pinned on top, the selected tab below it, tabs at the bottom (so
  /// dragging bands never fights the scroll view).
  Widget _portrait() {
    final c = widget.constraints;
    final graphHeight = (c.maxHeight * 0.36).clamp(200.0, 360.0);
    return Column(
      children: [
        if (_showGraph)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: SizedBox(height: graphHeight, child: widget.graph),
          ),
        Expanded(child: _tabView(c.maxWidth >= 480 ? 2 : 1)),
        NavigationBar(
          height: 64,
          backgroundColor: Palette.panel,
          indicatorColor: Palette.input,
          selectedIndex: _tab,
          onDestinationSelected: _select,
          destinations: [
            for (final (icon, label) in _tabs)
              NavigationDestination(
                icon: Icon(icon),
                selectedIcon: Icon(icon, color: Palette.accent),
                label: label,
              ),
          ],
        ),
      ],
    );
  }

  /// Graph uses the full height on the left, the selected tab in the
  /// middle, tabs as a rail on the right.
  Widget _landscape() => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_showGraph)
        Expanded(
          flex: 11,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
            child: widget.graph,
          ),
        ),
      Expanded(flex: 9, child: _tabView(1)),
      NavigationRail(
        backgroundColor: Palette.panel,
        indicatorColor: Palette.input,
        labelType: NavigationRailLabelType.all,
        minWidth: 64,
        groupAlignment: 0,
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: [
          for (final (icon, label) in _tabs)
            NavigationRailDestination(
              icon: Icon(icon),
              selectedIcon: Icon(icon, color: Palette.accent),
              label: Text(label),
            ),
        ],
      ),
    ],
  );
}

// ---- tablets and desktop ----------------------------------------------------

/// Graph on top, two columns of panels below.
class _MediumLayout extends StatelessWidget {
  final Widget graph;
  final BoxConstraints constraints;
  const _MediumLayout({required this.graph, required this.constraints});

  @override
  Widget build(BuildContext context) {
    final graphHeight = (constraints.maxHeight * 0.42).clamp(240.0, 520.0);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: SizedBox(height: graphHeight, child: graph),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      BandListPanel(rows: 5.5),
                      _gap,
                      BandEditorPanel(),
                      _gap,
                      PushSettingsPanel(),
                      _gap,
                      PeqEnablePanel(),
                      _gap,
                      LibraryPanel(rows: 4),
                    ],
                  ),
                ),
                _gap,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Section(
                        title: 'Actions',
                        child: ButtonGrid(
                          columns: 2,
                          actions: HomeScope.of(context).allActions,
                        ),
                      ),
                      _gap,
                      const DevicePanel(),
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
}

/// Graph and panels on the left, actions and library rail on the right.
class _ExpandedLayout extends StatelessWidget {
  final Widget graph;
  final BoxConstraints constraints;
  const _ExpandedLayout({required this.graph, required this.constraints});

  @override
  Widget build(BuildContext context) {
    final listWidth = (constraints.maxWidth * 0.28).clamp(300.0, 420.0);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(flex: 5, child: graph),
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
                            SizedBox(
                              width: listWidth,
                              child: const BandListPanel(rows: 6.5),
                            ),
                            _gap,
                            const Expanded(child: BandEditorPanel()),
                          ],
                        ),
                        _gap,
                        const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: PushSettingsPanel()),
                            _gap,
                            Expanded(child: PeqEnablePanel()),
                          ],
                        ),
                        _gap,
                        const DevicePanel(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          _gap,
          const SizedBox(
            width: 240,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [ActionsRail(), _gap, LibraryPanel(rows: 5)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
