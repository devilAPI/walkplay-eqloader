import 'package:flutter/material.dart';

/// "Instrument panel": graphite chassis, two-LED accent.
abstract final class Palette {
  static const chassis = Color(0xFF14161A); // deep graphite base
  static const panel = Color(0xFF1C1F26); // raised frame / surface
  static const input = Color(0xFF262A33); // entries, hover
  static const line = Color(0xFF2E333D); // hairline borders / grid
  static const ink = Color(0xFFE6E9EF); // primary text
  static const muted = Color(0xFF8A93A3); // secondary labels
  static const accent = Color(0xFF4ED0C4); // cyan signal / idle trace
  static const accentDark = Color(0xFF2C8F87); // pressed / darker cyan
  static const active = Color(0xFFF0A93B); // amber, selected band
  static const danger = Color(0xFFE5687A); // destructive action
}

const monoFont = 'monospace';
const monoFallback = [
  'JetBrains Mono',
  'DejaVu Sans Mono',
  'Menlo',
  'Courier New',
];

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    surface: Palette.chassis,
    onSurface: Palette.ink,
    primary: Palette.accent,
    onPrimary: Palette.chassis,
    secondary: Palette.active,
    onSecondary: Palette.chassis,
    error: Palette.danger,
    onError: Palette.chassis,
    outline: Palette.line,
    surfaceContainerHighest: Palette.input,
    surfaceContainerHigh: Palette.panel,
    surfaceContainer: Palette.panel,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(4),
    borderSide: const BorderSide(color: Palette.line),
  );
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(4),
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.chassis,
    canvasColor: Palette.panel,
    dividerColor: Palette.line,
    // Compact on desktop, standard (bigger touch targets) on phones/tablets.
    visualDensity: VisualDensity.adaptivePlatformDensity,
    appBarTheme: const AppBarTheme(
      backgroundColor: Palette.panel,
      foregroundColor: Palette.ink,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: Palette.ink,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Palette.input,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: Palette.accent),
      ),
      labelStyle: const TextStyle(color: Palette.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.input,
        foregroundColor: Palette.ink,
        shape: buttonShape,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.ink,
        side: const BorderSide(color: Palette.line),
        shape: buttonShape,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Palette.chassis,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: Palette.line),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(color: Palette.input),
      textStyle: TextStyle(color: Palette.ink, fontSize: 12),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.selected) ? Palette.accent : Palette.input,
      ),
      checkColor: const WidgetStatePropertyAll(Palette.chassis),
    ),
  );
}

enum ButtonKind { normal, accent, danger }

ButtonStyle? styleFor(ButtonKind kind) => switch (kind) {
  ButtonKind.normal => null,
  ButtonKind.accent => FilledButton.styleFrom(
    backgroundColor: Palette.accent,
    foregroundColor: Palette.chassis,
    textStyle: const TextStyle(fontWeight: FontWeight.bold),
  ),
  ButtonKind.danger => FilledButton.styleFrom(
    backgroundColor: Palette.input,
    foregroundColor: Palette.danger,
  ),
};

/// A titled frame, like the desktop app's LabelFrames.
class Section extends StatelessWidget {
  final String title;
  final Widget child;
  final EdgeInsets padding;
  final Widget? trailing;

  const Section({
    super.key,
    required this.title,
    required this.child,
    this.padding = const EdgeInsets.all(8),
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Palette.chassis,
        border: Border.all(color: Palette.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
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
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}
