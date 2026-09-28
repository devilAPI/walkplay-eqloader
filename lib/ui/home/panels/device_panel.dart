import 'package:flutter/material.dart';

import '../../../core/walkplay.dart';
import '../../../hid/hid.dart';
import '../../../state/device_controller.dart';
import '../../../state/profile_library.dart';
import '../../format.dart';
import '../../theme.dart';
import '../../widgets/fields.dart';
import '../../widgets/section.dart';
import '../home_controller.dart';

/// Device list, VID/PID, and what was last pushed to each slot.
class DevicePanel extends StatelessWidget {
  const DevicePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final device = home.device;
    final commands = home.deviceCommands;
    return ListenableBuilder(
      listenable: device,
      builder: (context, _) => Section(
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
                    child: _DeviceList(device),
                  ),
                ),
                const SizedBox(width: 8),
                IntrinsicWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (device.backend.needsAccessRequest) ...[
                        FilledButton(
                          style: styleFor(ButtonKind.accent),
                          onPressed: commands.connect,
                          child: const Text('Connect Device'),
                        ),
                        const SizedBox(height: 4),
                      ],
                      Tooltip(
                        message: 'F5',
                        child: FilledButton(
                          onPressed: commands.refresh,
                          child: const Text('Refresh List'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Tooltip(
                        message: 'Ctrl+G',
                        child: FilledButton(
                          onPressed: commands.getSlot,
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
                SmallField(
                  label: 'VID (hex)',
                  text: device.vidText,
                  width: 100,
                  onChanged: (t) => device.setText(vid: t),
                ),
                SmallField(
                  label: 'PID (hex, optional)',
                  text: device.pidText,
                  width: 150,
                  onChanged: (t) => device.setText(pid: t),
                ),
              ],
            ),
            _SlotMap(device, home.library),
          ],
        ),
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  final DeviceController device;
  const _DeviceList(this.device);

  @override
  Widget build(BuildContext context) {
    if (!device.loaded) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (device.devices.isEmpty) {
      return Center(
        child: Text(
          device.unavailableReason ??
              (device.backend.needsAccessRequest
                  ? '(click Connect Device to choose your dongle)'
                  : '(no Walkplay-vendor devices found)'),
          style: const TextStyle(color: Palette.muted),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView(children: [for (final d in device.devices) _deviceRow(d)]);
  }

  Widget _deviceRow(HidDeviceInfo d) {
    final sel = identical(d, device.selected);
    return InkWell(
      onTap: () => device.select(d),
      child: Container(
        color: sel ? Palette.accent : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          'pid=0x${hex4(d.productId)} iface=${d.interfaceNumber}  '
          '${d.product}',
          style: TextStyle(color: sel ? Palette.chassis : Palette.ink),
        ),
      ),
    );
  }
}

/// "Slot 0: Harman IEM · pushed 28 Sep 14:03" for the chosen device.
class _SlotMap extends StatelessWidget {
  final DeviceController device;
  final ProfileLibrary library;
  const _SlotMap(this.device, this.library);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: library,
    builder: (context, _) {
      final key = device.deviceKey;
      final slots = key == null ? const <Never>[] : library.slotsOf(key);
      if (slots.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'LAST WRITTEN / READ',
              style: TextStyle(
                color: Palette.muted,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 4),
            for (final (slot, record) in slots)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'Slot $slot  ',
                        style: monoStyle(size: 12, color: Palette.muted),
                      ),
                      TextSpan(
                        text: record.profile ?? 'unsaved EQ',
                        style: TextStyle(
                          color: record.profile != null
                              ? Palette.ink
                              : Palette.muted,
                          fontStyle: record.profile != null
                              ? FontStyle.normal
                              : FontStyle.italic,
                        ),
                      ),
                      TextSpan(
                        text: '  ${formatWhen(record.at)}',
                        style: const TextStyle(
                          color: Palette.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
