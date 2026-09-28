import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/eq_model.dart';
import '../theme.dart';

class LabeledRow extends StatelessWidget {
  final String label;
  final Widget child;
  const LabeledRow({super.key, required this.label, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: MediaQuery.sizeOf(context).width < 480 ? 96 : 120,
          child: Text(label),
        ),
        Expanded(child: child),
      ],
    ),
  );
}

/// A number entry with -/+ steppers (the desktop app's Spinbox).
class NumberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool enabled;
  final double step, min, max;
  final int decimals;
  final ValueChanged<String> onChanged;

  const NumberField({
    super.key,
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
  Widget build(BuildContext context) => LabeledRow(
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

/// A narrow labelled entry bound to a text value held elsewhere.
///
/// [text] must be exactly what was typed (not a reformatted value): it
/// replaces the field's contents whenever it changes from outside (undo,
/// picking a device), and equals them after every keystroke.
class SmallField extends StatefulWidget {
  final String label;
  final String text;
  final double width;
  final bool intOnly;
  final ValueChanged<String> onChanged;
  final String? helperText;

  const SmallField({
    super.key,
    required this.label,
    required this.text,
    required this.width,
    required this.onChanged,
    this.intOnly = false,
    this.helperText,
  });

  @override
  State<SmallField> createState() => _SmallFieldState();
}

class _SmallFieldState extends State<SmallField> {
  late final _controller = TextEditingController(text: widget.text);

  @override
  void didUpdateWidget(SmallField old) {
    super.didUpdateWidget(old);
    if (widget.text != _controller.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: MediaQuery.textScalerOf(context).scale(widget.width),
    child: TextField(
      controller: _controller,
      // Floated labels are smaller, so they fit the narrow fields.
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helperText,
        helperMaxLines: 3,
        floatingLabelBehavior: FloatingLabelBehavior.always,
      ),
      keyboardType: widget.intOnly
          ? TextInputType.number
          : const TextInputType.numberWithOptions(decimal: true, signed: true),
      inputFormatters: widget.intOnly
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      onChanged: widget.onChanged,
    ),
  );
}
