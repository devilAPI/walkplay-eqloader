import 'package:flutter/material.dart';

import '../../../core/saved_profile.dart';
import '../../../state/eq_model.dart';
import '../../theme.dart';
import '../../widgets/section.dart';
import '../../widgets/select_builder.dart';
import '../home_controller.dart';

/// Profiles saved in the app, [rows] rows tall. Tapping one loads it; the
/// profile the editor currently holds is marked.
class LibraryPanel extends StatelessWidget {
  final double rows;
  const LibraryPanel({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final library = home.library;
    final model = home.model;
    final extent = isTouchPlatform(context) ? 48.0 : 40.0;
    return Section(
      title: 'Library',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in [home.saveToLibrary, home.importToLibrary])
            IconButton(
              tooltip: a.shortcut != null
                  ? '${a.label} (${a.shortcutLabel})'
                  : a.label,
              visualDensity: VisualDensity.compact,
              icon: Icon(a.icon, color: Palette.accent),
              onPressed: a.onPressed,
            ),
        ],
      ),
      child: Container(
        height: extent * rows,
        decoration: BoxDecoration(
          color: Palette.panel,
          border: Border.all(color: Palette.line),
        ),
        child: SelectBuilder(
          Listenable.merge([library, model]),
          () => (
            library.revision,
            library.matching(model.preampDb, model.filters)?.name,
          ),
          (context) {
            final profiles = library.profiles;
            if (profiles.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'No saved profiles yet. Save the current EQ with the '
                    'bookmark button above.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Palette.muted),
                  ),
                ),
              );
            }
            final current = library.matching(model.preampDb, model.filters);
            return ListView.builder(
              itemCount: profiles.length,
              itemExtent: extent,
              itemBuilder: (context, i) => _ProfileRow(
                profiles[i],
                current: profiles[i].name == current?.name,
              ),
            );
          },
        ),
      ),
    );
  }
}

enum _RowAction { load, rename, export, delete }

class _ProfileRow extends StatelessWidget {
  final SavedProfile profile;
  final bool current;
  const _ProfileRow(this.profile, {required this.current});

  @override
  Widget build(BuildContext context) {
    final commands = HomeScope.of(context).libraryCommands;
    final bands = profile.filters.length;
    return InkWell(
      onTap: () => commands.load(profile),
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: current
                  ? const Tooltip(
                      message: 'The EQ being edited is this profile',
                      child: Icon(Icons.check, size: 16, color: Palette.accent),
                    )
                  : null,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: current ? Palette.accent : Palette.ink,
                      fontWeight: current ? FontWeight.w600 : null,
                    ),
                  ),
                  Text(
                    '$bands band${bands == 1 ? '' : 's'} · '
                    'preamp ${fmtG(profile.preamp)} dB',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Palette.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            PopupMenuButton<_RowAction>(
              tooltip: 'Profile actions',
              icon: const Icon(Icons.more_vert, size: 18, color: Palette.muted),
              onSelected: (a) => switch (a) {
                _RowAction.load => commands.load(profile),
                _RowAction.rename => commands.rename(profile),
                _RowAction.export => commands.export(profile),
                _RowAction.delete => commands.delete(profile),
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: _RowAction.load, child: Text('Load')),
                PopupMenuItem(value: _RowAction.rename, child: Text('Rename…')),
                PopupMenuItem(
                  value: _RowAction.export,
                  child: Text('Export to File…'),
                ),
                PopupMenuItem(
                  value: _RowAction.delete,
                  child: Text(
                    'Delete',
                    style: TextStyle(color: Palette.danger),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
