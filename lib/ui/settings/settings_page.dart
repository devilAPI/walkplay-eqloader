import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../platform/pwa.dart';
import '../../state/eq_model.dart';
import '../../state/settings.dart';
import '../theme.dart';
import '../widgets/fields.dart';
import '../widgets/section.dart';
import 'about_page.dart';
import 'log_page.dart';

/// Settings as its own screen (desktop and tablets, from the gear icon).
class SettingsPage extends StatelessWidget {
  final Settings settings;
  final EqModel model;
  final String? hidUnavailableReason;

  const SettingsPage({
    super.key,
    required this.settings,
    required this.model,
    this.hidUnavailableReason,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: SettingsView(
      settings: settings,
      model: model,
      hidUnavailableReason: hidUnavailableReason,
    ),
  );
}

/// The settings list; phones show it as a tab.
class SettingsView extends StatefulWidget {
  final Settings settings;

  /// Whose log the Log page shows.
  final EqModel model;

  /// Why USB HID doesn't work here, for the diagnostics; null when it does.
  final String? hidUnavailableReason;

  const SettingsView({
    super.key,
    required this.settings,
    required this.model,
    this.hidUnavailableReason,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  Settings get _settings => widget.settings;

  // Kept as typed; only valid values reach the settings.
  late String _maxFilters = '${_settings.maxFilters}';
  late String _buffer = fmtG(_settings.bufferDb);

  PwaState _pwa = pwaState;

  Future<void> _install() async {
    await installPwa();
    if (mounted) setState(() => _pwa = pwaState);
  }

  void _open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _graphSection(),
              const SizedBox(height: 12),
              _deviceSection(),
              if (kIsWeb) ...[const SizedBox(height: 12), _webSection()],
              const SizedBox(height: 12),
              Section(
                title: 'More',
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.notes),
                      title: const Text('Log'),
                      subtitle: const Text(
                        'Device messages, errors and diagnostics',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _open(
                        LogPage(
                          model: widget.model,
                          hidUnavailableReason: widget.hidUnavailableReason,
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('About Walkplay PEQ Loader'),
                      subtitle: const Text(
                        'Version, source code, reporting problems',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _open(const AboutPage()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _graphSection() => Section(
    title: 'Graph',
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        SwitchListTile(
          title: const Text('Flat reference line'),
          subtitle: const Text(
            'A dashed line at the level you hear with the EQ off. The preamp '
            'shifts everything you hear, so the line moves the opposite way: '
            'with a −6 dB preamp it sits at +6 dB. Where the curve is above '
            'it, the EQ is louder than no EQ.',
          ),
          value: _settings.showFlatReference,
          onChanged: (v) => _settings.update(showFlatReference: v),
        ),
        SwitchListTile(
          title: const Text('Show Q as bandwidth'),
          subtitle: const Text('Edit band width in octaves instead of Q.'),
          value: _settings.qAsBandwidth,
          onChanged: (v) => _settings.update(qAsBandwidth: v),
        ),
      ],
    ),
  );

  Widget _deviceSection() => Section(
    title: 'Device',
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    child: Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        SmallField(
          label: 'Max filters',
          text: _maxFilters,
          width: 260,
          intOnly: true,
          helperText:
              'Filter slots your dongle has (8 on the Protocol Micro). '
              'Pushes are padded to this many.',
          onChanged: (t) {
            setState(() => _maxFilters = t);
            final v = parseIntText(t);
            if (v != null && v > 0) _settings.update(maxFilters: v);
          },
        ),
        SmallField(
          label: 'Hardware buffer (dB)',
          text: _buffer,
          width: 260,
          helperText:
              'Attenuation the dongle always applies (−5 dB on the '
              'Protocol Micro). The gain register only holds what the '
              'preamp needs beyond it.',
          onChanged: (t) {
            setState(() => _buffer = t);
            final v = parseDoubleText(t);
            if (v != null) _settings.update(bufferDb: v);
          },
        ),
      ],
    ),
  );

  Widget _webSection() => Section(
    title: 'Web App',
    padding: EdgeInsets.zero,
    child: switch (_pwa) {
      PwaState.installed => const ListTile(
        leading: Icon(Icons.check_circle_outline, color: Palette.accent),
        title: Text('Installed'),
        subtitle: Text(
          'Running as an installed app. It keeps working offline, except '
          'for downloading AutoEQ data you haven\'t opened before.',
        ),
      ),
      PwaState.installable => ListTile(
        leading: const Icon(Icons.install_desktop),
        title: const Text('Install as an app'),
        subtitle: const Text(
          'Opens in its own window, starts from your app list and works '
          'offline.',
        ),
        trailing: FilledButton(
          style: styleFor(ButtonKind.accent),
          onPressed: _install,
          child: const Text('Install'),
        ),
      ),
      PwaState.unavailable => const ListTile(
        leading: Icon(Icons.install_desktop),
        title: Text('Install as an app'),
        subtitle: Text(
          'Use your browser\'s install option (the install icon in the '
          'address bar, or the menu). Once loaded, the app also works '
          'offline.',
        ),
      ),
    },
  );
}
