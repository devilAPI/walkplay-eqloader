import '../../core/band.dart';
import '../../core/walkplay.dart';
import '../../state/device_controller.dart';
import '../../state/profile_library.dart';
import '../dialogs.dart';
import '../format.dart';
import '../task_host.dart';
import '../theme.dart';

/// Talking to the dongle, with the confirmations and error reporting around
/// it. Pushes and pulls are recorded in the library's slot map.
class DeviceCommands {
  final TaskHost host;
  final DeviceController device;
  final ProfileLibrary library;

  DeviceCommands(this.host, this.device, this.library);

  void _log(String s) => host.model.log(s);

  Future<void> refresh() async {
    await host.runTask(device.refresh);
  }

  Future<void> connect() async {
    await host.runTask(device.requestAccess);
    await refresh();
  }

  /// Read the firmware version and active slot, and show them.
  Future<void> getSlot() async {
    final result = await host.runTask(
      () => device.withDevice((dev, d) async => (await dev.getInfo(), d)),
      error: ('Device Info', 'Could not read the device'),
    );
    if (result == null || !host.context.mounted) return;
    final (info, d) = result;
    final slot = info.slot < 0 ? 'unknown' : '${info.slot}';
    final lines = [
      'Device: ${d.product.isEmpty ? 'unnamed' : d.product} '
          '(0x${hex4(d.vendorId)}:0x${hex4(d.productId)})',
      'Firmware version: ${info.version.isEmpty ? 'unknown' : info.version}',
      'Active EQ slot: $slot',
    ];
    if (info.slot >= 0) {
      for (final (s, record) in library.slotsOf(DeviceController.keyOf(d))) {
        if (s != info.slot) continue;
        lines.add(
          'Last written/read: ${record.profile ?? 'an unsaved EQ'} '
          '(${formatWhen(record.at)})',
        );
      }
    }
    await showInfo(host.context, 'Device Info', lines.join('\n'));
  }

  Future<void> enable() async {
    final slot = device.enableSlot;
    await host.runTask(
      () => device.withDevice((dev, _) async {
        await dev.enablePeq(true, slot);
        _log('PEQ enabled on slot $slot');
      }),
    );
  }

  Future<void> disable() async {
    await host.runTask(
      () => device.withDevice((dev, _) async {
        await dev.enablePeq(false);
        _log('PEQ disabled');
      }),
    );
  }

  Future<void> loadFromDevice() async {
    final model = host.model;
    if (!await askYesNo(
      host.context,
      'Load EQ from Device',
      'Load EQ from device? This will replace all current filters.',
    )) {
      return;
    }
    final max = host.settings.maxFilters;
    final buffer = host.settings.bufferDb;
    final pulled = await host.runTask(
      () => device.withDevice(
        (dev, info) async => (
          await dev.pull(
            max,
            slotHint: await dev.getCurrentSlot(),
            bufferDb: buffer,
          ),
          DeviceController.keyOf(info),
        ),
      ),
    );
    if (pulled == null) return;
    final (result, deviceKey) = pulled;
    model.setFilters(result.filters, result.preamp);
    if (result.currentSlot >= 0) {
      final saved = library.matching(
        model.preampDb,
        model.filters,
        asStored: true,
      );
      library.recordSlot(deviceKey, result.currentSlot, saved?.name);
      if (saved != null) {
        _log('Slot ${result.currentSlot} holds "${saved.name}"');
      }
    }
  }

  /// Push the EQ; true after a successful push. [confirm] false when the
  /// user already chose to push (the quit dialog).
  Future<bool> push({bool confirm = true}) async {
    final model = host.model;
    final context = host.context;
    if (model.filters.isEmpty) {
      await showInfo(context, 'No Filters', 'Add at least one EQ band first.');
      return false;
    }
    final slot = device.pushSlot;
    if (confirm &&
        !await askYesNo(
          context,
          'Push EQ to Device',
          'Push ${model.filters.length} band(s) to slot $slot on the device? '
              'This overwrites the EQ stored in that slot.',
        )) {
      return false;
    }
    if (!context.mounted) return false;
    final preamp = model.preampDb;
    final buffer = host.settings.bufferDb;
    final max = host.settings.maxFilters;
    final count = model.filters.length;

    if (count > max &&
        await askChoice<String>(
              context,
              'Too Many Bands',
              'You have $count EQ bands, but the device is set to support '
                  'only $max filter slot(s) (Settings → Max filters).\n\n'
                  'Only the first $max band(s) would be written to the device '
                  '— the rest would be silently dropped.\n\n'
                  'Reduce your EQ to $max band(s), correct \'Max filters\' to '
                  'match your device, or push anyway (will break your EQ).',
              [
                ('Cancel', null, ButtonKind.normal),
                ('Push Anyway', 'push', ButtonKind.danger),
              ],
              focus: 'Cancel',
            ) !=
            'push') {
      return false;
    }

    final saved = library.matching(preamp, model.filters);
    final trimmed = model.filters.length > max ? model.filters.sublist(0, max) : model.filters;
    final filters = padForPush(trimmed, max);
    final ok = await host.runTask(
      () => device.withDevice((dev, info) async {
        await dev.push(slot, preamp, filters, bufferDb: buffer);
        await dev.enablePeq(true, slot);
        _log(
          'EQ pushed to device on slot $slot (${filters.length} slots)'
          '${saved != null ? ': "${saved.name}"' : ''}',
        );
        library.recordSlot(DeviceController.keyOf(info), slot, saved?.name);
        return true;
      }),
    );
    return ok == true;
  }
}
