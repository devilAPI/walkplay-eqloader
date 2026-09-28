import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import '../../widgets/section.dart';
import '../../widgets/select_builder.dart';
import '../home_controller.dart';

/// The band list, [rows] rows tall.
///
/// [headerActions]: add/delete as icons in the header (phones, where a row of
/// text buttons costs too much height).
class BandListPanel extends StatelessWidget {
  final double rows;
  final bool headerActions;
  const BandListPanel({
    super.key,
    required this.rows,
    this.headerActions = false,
  });

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final model = home.model;
    final extent = isTouchPlatform(context) ? 40.0 : 30.0;
    return SelectBuilder(model, () => model.filters.length, (context) {
      return Section(
        title: headerActions ? 'Filters (${model.filters.length})' : 'Filters',
        trailing: headerActions
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final a in home.bandActions)
                    IconButton(
                      tooltip: a.label,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        a.icon,
                        color: a.kind == ButtonKind.danger
                            ? Palette.danger
                            : Palette.accent,
                      ),
                      onPressed: a.onPressed,
                    ),
                ],
              )
            : Text(
                '${model.filters.length} band(s)',
                style: const TextStyle(color: Palette.muted, fontSize: 11),
              ),
        child: Container(
          height: extent * rows,
          decoration: BoxDecoration(
            color: Palette.panel,
            border: Border.all(color: Palette.line),
          ),
          child: model.filters.isEmpty
              ? const Center(
                  child: Text(
                    'No bands. Tap the graph or "Add Band".',
                    style: TextStyle(color: Palette.muted),
                  ),
                )
              : ListView.builder(
                  itemCount: model.filters.length,
                  itemExtent: extent,
                  itemBuilder: (context, i) => _BandRow(i),
                ),
        ),
      );
    });
  }
}

/// Rebuilds only when its own text or highlight changes, i.e. just the
/// dragged band during a drag.
class _BandRow extends StatelessWidget {
  final int index;
  const _BandRow(this.index);

  @override
  Widget build(BuildContext context) {
    final model = HomeScope.of(context).model;
    final i = index;
    return SelectBuilder(
      model,
      () {
        if (i >= model.filters.length) return null;
        final f = model.filters[i];
        return (f.freq, f.gain, f.q, f.type, model.selection.contains(i));
      },
      (context) {
        if (i >= model.filters.length) return const SizedBox.shrink();
        final f = model.filters[i];
        final sel = model.selection.contains(i);
        return InkWell(
          onTap: () {
            final kb = HardwareKeyboard.instance;
            if (kb.isControlPressed) {
              model.toggleSelect(i);
            } else if (kb.isShiftPressed) {
              model.rangeSelect(i);
            } else {
              model.select(i);
            }
          },
          onLongPress: () => model.toggleSelect(i),
          child: Container(
            color: sel ? Palette.accent : null,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            child: Text(
              '${i + 1}: ${f.freq.toStringAsFixed(1)} Hz  '
              '${f.gain.toStringAsFixed(1)} dB  '
              'Q ${f.q.toStringAsFixed(2)}  ${f.type}',
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: monoStyle(color: sel ? Palette.chassis : Palette.ink),
            ),
          ),
        );
      },
    );
  }
}
