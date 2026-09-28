import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eqloader/main.dart';
import 'package:eqloader/core/walkplay.dart';
import 'package:eqloader/hid/hid.dart';
import 'package:eqloader/state/eq_model.dart';
import 'package:eqloader/state/store.dart';
import 'package:eqloader/ui/eq_graph.dart';
import 'package:eqloader/ui/settings/settings_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EqModel', () {
    test('undo/redo restores bands, preamp and selection', () {
      final m = EqModel();
      m.addBand();
      m.applyField('gain', 4.0);
      m.applyField('gain', 5.0); // same edit session: one undo step
      expect(m.filters.length, 2);
      expect(m.filters[1].gain, 5.0);

      m.undo();
      expect(m.filters[1].gain, 0.0);
      m.undo();
      expect(m.filters.length, 1);
      m.redo();
      m.redo();
      expect(m.filters[1].gain, 5.0);
    });

    test('multi-selection edits every selected band', () {
      final m = EqModel()
        ..addBand()
        ..addBand()
        ..select(0)
        ..toggleSelect(2);
      m.applyField('q', 2.5);
      expect([for (final f in m.filters) f.q], [2.5, 1.0, 2.5]);
      m.deleteSelected();
      expect(m.filters.length, 1);
    });

    test('graph drag is one undo step, a plain click none', () {
      final m = EqModel();
      m.beginDragExisting(0);
      m.endDrag();
      expect(m.canUndo, isFalse);
      m.beginDragExisting(0);
      m.dragTo(0, 250, 3);
      m.dragTo(0, 300, 4);
      m.endDrag();
      m.undo();
      expect(m.filters[0].freq, 1000);
      expect(m.canUndo, isFalse);
    });
  });

  final platforms = TargetPlatformVariant({
    TargetPlatform.linux,
    TargetPlatform.android,
  });

  for (final (name, size) in [
    ('phone portrait', const Size(390, 844)),
    ('phone landscape', const Size(844, 390)),
    ('tablet portrait', const Size(820, 1180)),
    ('tablet landscape', const Size(1180, 820)),
    ('small desktop window', const Size(950, 700)),
    ('desktop', const Size(1920, 1080)),
  ]) {
    testWidgets('lays out and edits bands on $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const EqLoaderApp());
      await tester.pumpAndSettle();
      expect(find.text('Walkplay PEQ Loader'), findsOneWidget);
      expect(find.textContaining('1: 1000.0 Hz'), findsOneWidget);

      // Phones: an icon in the band list header; else a text button.
      final addIcon = find.byTooltip('Add Band');
      if (addIcon.evaluate().isNotEmpty) {
        await tester.tap(addIcon);
        await tester.pumpAndSettle();
      } else {
        await revealText(tester, 'Add Band');
        await tester.ensureVisible(find.text('Add Band'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Band'));
        await tester.pumpAndSettle();
        // Scroll the band list back into view (single-column layouts).
        await tester.drag(find.text('Add Band'), const Offset(0, 3000));
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('2: 1000.0 Hz'), findsOneWidget);

      await tester.tap(find.byTooltip('Undo (Ctrl+Z)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2: 1000.0 Hz'), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }

  testWidgets('dragging a graph handle moves the band', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const EqLoaderApp());
    await tester.pumpAndSettle();

    // Band 1 (1000 Hz, 0 dB) sits at this point of the plot area; see _Axes.
    final r = tester.getRect(find.byType(EqGraph));
    final plotLeft = r.left + 36, plotWidth = r.width - 44;
    final handle = Offset(
      plotLeft + plotWidth * (math.log(1000 / 20) / math.log(1000)),
      r.top + 24 + (r.height - 44) / 2,
    );
    final gesture = await tester.startGesture(
      handle,
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(handle + Offset(6.0 * i, -5.0 * i));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.textContaining('1: 1000.0 Hz'), findsNothing);
    expect(find.textContaining(' dB  Q 1.00  PK'), findsOneWidget);
    // The whole drag is a single undo step.
    await tester.tap(find.byTooltip('Undo (Ctrl+Z)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1: 1000.0 Hz  0.0 dB'), findsOneWidget);
  });

  testWidgets('saves to the library, marks and reloads the profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    await tester.pumpWidget(EqLoaderApp(store: store));
    await tester.pumpAndSettle();
    expect(find.textContaining('No saved profiles'), findsOneWidget);

    await tester.tap(find.byTooltip('Save to Library (Ctrl+Shift+S)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'My EQ');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('My EQ'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget); // it's the current EQ

    await tester.tap(find.text('Add Band'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2: 1000.0 Hz'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);

    await tester.tap(find.text('My EQ'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2: 1000.0 Hz'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);

    // Stored: a fresh app on the same store lists it.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(EqLoaderApp(store: store));
    await tester.pumpAndSettle();
    expect(find.text('My EQ'), findsOneWidget);
  });

  testWidgets('settings toggle the flat reference and open About', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const EqLoaderApp());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_box_outlined), findsOneWidget); // on

    await tester.tap(find.text('Settings')); // phone tab
    await tester.pumpAndSettle();
    expect(find.byType(EqGraph), findsNothing);
    await tester.tap(find.text('Flat reference line'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('About Walkplay PEQ Loader'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(SettingsView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    // Built but possibly under the tab bar: bring it fully into view.
    await tester.ensureVisible(find.text('About Walkplay PEQ Loader'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About Walkplay PEQ Loader'));
    await tester.pumpAndSettle();
    expect(find.text('Source code on GitHub'), findsOneWidget);
    expect(find.text('dev'), findsOneWidget); // no APP_VERSION in tests
    expect(tester.takeException(), isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Log'));
    await tester.pumpAndSettle();
    expect(find.text('DIAGNOSTICS'), findsOneWidget);
    expect(find.textContaining('USB HID:'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Back on the EQ tab, the graph returns with the reference switched off.
    await tester.tap(find.text('EQ'));
    await tester.pumpAndSettle();
    expect(find.byType(EqGraph), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Get Slot / Version shows the device info', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EqLoaderApp(backend: FakeDongle()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get Slot / Version'));
    await tester.pumpAndSettle();
    expect(find.text('Device Info'), findsOneWidget);
    expect(find.textContaining('Firmware version: 1.7'), findsOneWidget);
    expect(find.textContaining('Active EQ slot: 2'), findsOneWidget);
    expect(
      find.textContaining('Protocol Micro (0x3302:0xC20F)'),
      findsOneWidget,
    );
  });
}

/// Scroll the page (the outermost scrollable) until [text] is built; in
/// single-column layouts lower sections are built lazily.
Future<void> revealText(WidgetTester tester, String text) async {
  for (var i = 0; i < 60 && find.text(text).evaluate().isEmpty; i++) {
    final page = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .first
        .position;
    page.jumpTo(math.min(page.pixels + 150, page.maxScrollExtent));
    await tester.pump();
  }
}

/// A dongle that answers the version and slot queries.
class FakeDongle extends HidBackend implements HidConnection {
  static const info = HidDeviceInfo(
    vendorId: walkplayVendorId,
    productId: 0xC20F,
    interfaceNumber: 3,
    product: 'Protocol Micro',
    manufacturer: 'Walkplay',
    path: 'fake',
  );

  final _replies = Queue<Uint8List>();

  @override
  Future<List<HidDeviceInfo>> enumerate() async => [info];

  @override
  Future<HidConnection> open(HidDeviceInfo device) async => this;

  @override
  Future<void> write(Uint8List data) async {
    // data: report id, read/write, command, ...
    final reply = Uint8List(reportLength + 1)
      ..[0] = reportId
      ..[2] = data[2];
    if (data[2] == cmdVersion) reply.setAll(4, '1.7'.codeUnits);
    if (data[2] == cmdPeqValues) reply[36] = 2;
    _replies.add(reply);
  }

  @override
  Future<Uint8List?> read(Duration timeout) async =>
      _replies.isEmpty ? null : _replies.removeFirst();

  @override
  Future<void> close() async {}
}
