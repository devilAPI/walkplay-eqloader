import 'package:flutter/material.dart';

import '../theme.dart';

/// A titled frame, like the desktop app's LabelFrames.
class Section extends StatelessWidget {
  final String title;
  final Widget child;
  final EdgeInsets padding;
  final Widget? trailing;

  /// Fill the available height, giving the rest to [child].
  final bool expand;

  const Section({
    super.key,
    required this.title,
    required this.child,
    this.padding = const EdgeInsets.all(8),
    this.trailing,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    // Ink (list tiles, buttons) must paint above the frame's background.
    final body = Material(
      type: MaterialType.transparency,
      child: Padding(padding: padding, child: child),
    );
    return Container(
      decoration: BoxDecoration(
        color: Palette.chassis,
        border: Border.all(color: Palette.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(
              children: [
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    color: Palette.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                ?trailing,
              ],
            ),
          ),
          if (expand) Expanded(child: body) else body,
        ],
      ),
    );
  }
}
