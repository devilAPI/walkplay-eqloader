import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/fields.dart';
import '../../widgets/section.dart';
import '../home_controller.dart';

class PreampField extends StatelessWidget {
  const PreampField({super.key});

  @override
  Widget build(BuildContext context) {
    final model = HomeScope.of(context).model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => SmallField(
        label: 'Preamp (dB)',
        text: model.preamp,
        width: 110,
        onChanged: model.setPreampText,
      ),
    );
  }
}

/// The slot pushes go to.
class PushSlotField extends StatelessWidget {
  const PushSlotField({super.key});

  @override
  Widget build(BuildContext context) {
    final device = HomeScope.of(context).device;
    return ListenableBuilder(
      listenable: device,
      builder: (context, _) => SmallField(
        label: 'Slot',
        text: device.pushSlotText,
        width: 70,
        intOnly: true,
        onChanged: (t) => device.setText(pushSlot: t),
      ),
    );
  }
}

/// Push slot and preamp (desktop and tablet layouts).
class PushSettingsPanel extends StatelessWidget {
  const PushSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) => const Section(
    title: 'EQ',
    child: Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [PushSlotField(), PreampField()],
    ),
  );
}

class PeqEnablePanel extends StatelessWidget {
  const PeqEnablePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final device = home.device;
    return Section(
      title: 'PEQ Enable / Disable',
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ListenableBuilder(
            listenable: device,
            builder: (context, _) => SmallField(
              label: 'Slot',
              text: device.enableSlotText,
              width: 70,
              intOnly: true,
              onChanged: (t) => device.setText(enableSlot: t),
            ),
          ),
          Tooltip(
            message: 'Ctrl+Shift+E',
            child: FilledButton(
              style: styleFor(ButtonKind.accent),
              onPressed: home.deviceCommands.enable,
              child: const Text('Enable PEQ'),
            ),
          ),
          Tooltip(
            message: 'Ctrl+Shift+X',
            child: FilledButton(
              style: styleFor(ButtonKind.danger),
              onPressed: home.deviceCommands.disable,
              child: const Text('Disable PEQ'),
            ),
          ),
        ],
      ),
    );
  }
}
