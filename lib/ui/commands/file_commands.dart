import '../../core/profile.dart';
import '../../platform/files.dart';
import '../../state/profile_library.dart';
import '../dialogs.dart';
import '../task_host.dart';
import 'library_commands.dart';

/// Profile .txt files (EqualizerAPO / eq.hangout.audio format).
class FileCommands {
  final TaskHost host;
  final ProfileLibrary library;

  FileCommands(this.host, this.library);

  /// Save the EQ to a file; true once saved.
  Future<bool> save() async {
    final model = host.model;
    if (model.filters.isEmpty) {
      await showInfo(
        host.context,
        'No Filters',
        'Add at least one EQ band first.',
      );
      return false;
    }
    final saved = library.matching(model.preampDb, model.filters);
    final content = formatProfile(model.preampDb, model.filters);
    final path = await host.runTask(
      () => saveTextFile(
        'Save Profile',
        saved != null ? '${safeFileName(saved.name)}.txt' : 'eq_profile.txt',
        content,
      ),
      error: ('Save Error', 'Could not save the profile'),
    );
    if (path == null) return false;
    model.log('Profile saved to $path');
    return true;
  }

  Future<void> load() async {
    final picked = await host.runTask(
      () => pickTextFile('Load Profile', const ['txt']),
      error: ('Load Error', 'Could not open the file'),
    );
    if (picked == null || !host.context.mounted) return;
    try {
      final profile = parseProfile(picked.content, source: picked.name);
      host.model
        ..setFilters(profile.filters, profile.preamp)
        ..log(
          'Loaded ${host.model.filters.length} filter(s) from ${picked.name}',
        );
    } catch (e) {
      await showInfo(host.context, 'Load Error', errorText(e));
    }
  }
}
