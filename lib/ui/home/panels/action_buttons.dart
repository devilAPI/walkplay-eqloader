import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/section.dart';
import '../home_controller.dart';

/// Every action stacked in one column (desktop rail).
class ActionsRail extends StatelessWidget {
  const ActionsRail({super.key});

  @override
  Widget build(BuildContext context) {
    final touch = isTouchPlatform(context);
    return Section(
      title: 'Actions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final a in HomeScope.of(context).allActions)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: touch ? 52 : 46),
                child: ActionButton(a),
              ),
            ),
        ],
      ),
    );
  }
}

/// [actions] in rows of [columns]; each row is as tall as its tallest label
/// needs (long labels wrap instead of being clipped).
class ButtonGrid extends StatelessWidget {
  final int columns;
  final List<AppAction> actions;
  const ButtonGrid({super.key, required this.columns, required this.actions});

  @override
  Widget build(BuildContext context) {
    const spacing = 6.0;
    final minHeight = isTouchPlatform(context) ? 48.0 : 42.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < actions.length; r += columns)
          Padding(
            padding: EdgeInsets.only(top: r == 0 ? 0 : spacing),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = r; i < r + columns; i++) ...[
                    if (i > r) const SizedBox(width: spacing),
                    Expanded(
                      child: i < actions.length
                          ? ConstrainedBox(
                              constraints: BoxConstraints(minHeight: minHeight),
                              child: ActionButton(actions[i]),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class ActionButton extends StatelessWidget {
  final AppAction action;
  const ActionButton(this.action, {super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: action.shortcutLabel,
    waitDuration: const Duration(milliseconds: 600),
    child: FilledButton(
      style: (styleFor(action.kind) ?? const ButtonStyle()).merge(
        FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
      ),
      onPressed: action.onPressed,
      child: Text(action.label, textAlign: TextAlign.center),
    ),
  );
}
