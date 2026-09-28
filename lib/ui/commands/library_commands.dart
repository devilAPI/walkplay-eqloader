import '../../core/profile.dart';
import '../../core/saved_profile.dart';
import '../../platform/files.dart';
import '../../state/profile_library.dart';
import '../dialogs.dart';
import '../task_host.dart';

/// The profile library's actions: save the current EQ, load, rename,
/// delete, import from and export to profile .txt files.
class LibraryCommands {
  final TaskHost host;
  final ProfileLibrary library;

  LibraryCommands(this.host, this.library);

  void _log(String s) => host.model.log(s);

  /// The library profile the editor currently holds, if any.
  SavedProfile? get current =>
      library.matching(host.model.preampDb, host.model.filters);

  Future<void> saveCurrent() async {
    final model = host.model;
    if (model.filters.isEmpty) {
      await showInfo(
        host.context,
        'No Filters',
        'Add at least one EQ band first.',
      );
      return;
    }
    final name = await askText(
      host.context,
      'Save to Library',
      'Profile name',
      initial: current?.name ?? '',
      confirm: 'Save',
    );
    if (name == null || !host.context.mounted) return;
    if (!await _confirmReplace(name, model.preampDb)) return;
    library.save(
      SavedProfile(
        name: name,
        preamp: model.preampDb,
        filters: model.filters,
        saved: DateTime.now(),
      ),
    );
    _log('Saved "$name" to the library');
  }

  /// Ask before overwriting a different profile of the same name.
  Future<bool> _confirmReplace(String name, double preamp) async {
    final existing = library.byName(name);
    if (existing == null || existing.matches(preamp, host.model.filters)) {
      return true;
    }
    return askYesNo(
      host.context,
      'Replace Profile',
      'The library already has a profile named "${existing.name}". '
          'Replace it?',
    );
  }

  void load(SavedProfile profile) {
    host.model.setFilters(profile.filters, profile.preamp, clean: false);
    _log('Loaded "${profile.name}" from the library');
  }

  Future<void> rename(SavedProfile profile) async {
    final name = await askText(
      host.context,
      'Rename Profile',
      'New name',
      initial: profile.name,
      confirm: 'Rename',
    );
    if (name == null || name == profile.name) return;
    final clash = library.byName(name);
    if (clash != null && clash.name != profile.name) {
      if (host.context.mounted) {
        await showInfo(
          host.context,
          'Rename Profile',
          'The library already has a profile named "${clash.name}".',
        );
      }
      return;
    }
    library.rename(profile, name);
  }

  Future<void> delete(SavedProfile profile) async {
    if (await askYesNo(
      host.context,
      'Delete Profile',
      'Delete "${profile.name}" from the library? This can\'t be undone.',
    )) {
      library.delete(profile);
      _log('Deleted "${profile.name}" from the library');
    }
  }

  Future<void> export(SavedProfile profile) async {
    final path = await host.runTask(
      () => saveTextFile(
        'Export Profile',
        '${safeFileName(profile.name)}.txt',
        formatProfile(profile.preamp, profile.filters),
      ),
      error: ('Export Error', 'Could not export the profile'),
    );
    if (path != null) _log('Exported "${profile.name}" to $path');
  }

  /// Add a profile .txt file to the library, named after the file.
  Future<void> importFile() async {
    final picked = await host.runTask(
      () => pickTextFile('Import Profile', const ['txt']),
      error: ('Import Error', 'Could not open the file'),
    );
    if (picked == null || !host.context.mounted) return;
    final Profile profile;
    try {
      profile = parseProfile(picked.content, source: picked.name);
    } catch (e) {
      await showInfo(host.context, 'Import Error', errorText(e));
      return;
    }
    if (!host.context.mounted) return;
    final base = picked.name.split(RegExp(r'[/\\]')).last;
    final name = await askText(
      host.context,
      'Import Profile',
      'Profile name',
      initial: base.replaceFirst(RegExp(r'\.txt$', caseSensitive: false), ''),
      confirm: 'Import',
    );
    if (name == null || !host.context.mounted) return;
    if (library.byName(name) != null &&
        !await askYesNo(
          host.context,
          'Replace Profile',
          'The library already has a profile named "$name". Replace it?',
        )) {
      return;
    }
    library.save(
      SavedProfile(
        name: name,
        preamp: profile.preamp,
        filters: profile.filters,
        saved: DateTime.now(),
      ),
    );
    _log('Imported "$name" into the library');
  }
}

/// [name] with characters that file systems reject replaced.
String safeFileName(String name) {
  final s = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  return s.isEmpty ? 'eq_profile' : s;
}
