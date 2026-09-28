import 'package:flutter/material.dart';

import '../../../core/band.dart';
import '../../../core/dsp.dart';
import '../../../state/eq_model.dart';
import '../../theme.dart';
import '../../widgets/fields.dart';
import '../../widgets/section.dart';
import '../../widgets/select_builder.dart';
import '../home_controller.dart';

/// Frequency/gain/Q/type of the selected band(s), live-applied while typing.
class BandEditorPanel extends StatefulWidget {
  const BandEditorPanel({super.key});

  @override
  State<BandEditorPanel> createState() => _BandEditorPanelState();
}

class _BandEditorPanelState extends State<BandEditorPanel> {
  late final HomeController _home = HomeScope.of(context);
  late final Listenable _changes = Listenable.merge([
    _home.model,
    _home.settings,
  ]);

  final _freq = TextEditingController();
  final _gain = TextEditingController();
  final _q = TextEditingController();
  String _type = 'PK';
  int _fieldsRevision = -1;
  bool? _bwShown;

  EqModel get _model => _home.model;
  bool get _bw => _home.settings.qAsBandwidth;

  @override
  void initState() {
    super.initState();
    _changes.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    _changes.removeListener(_sync);
    _freq.dispose();
    _gain.dispose();
    _q.dispose();
    super.dispose();
  }

  /// Reload the fields when the selection/band changed from elsewhere, or
  /// the Q unit was switched.
  void _sync() {
    if (_fieldsRevision == _model.fieldsRevision && _bwShown == _bw) return;
    _fieldsRevision = _model.fieldsRevision;
    _bwShown = _bw;
    final f = _model.primary;
    if (f == null) {
      _freq.text = _gain.text = _q.text = '';
      _type = 'PK';
      return;
    }
    _setText(_freq, f.freq.toString());
    _setText(_gain, f.gain.toString());
    _setText(_q, _bw ? qToBw(f.q).toStringAsFixed(3) : f.q.toString());
    _type = f.type;
  }

  /// Assigning even unchanged text resets the selection and relayouts the
  /// field; this runs several times a second while a band is dragged.
  static void _setText(TextEditingController c, String text) {
    if (c.text != text) c.text = text;
  }

  void _apply(String field, String text) {
    if (field == 'type') {
      _model.applyField('type', text);
      return;
    }
    var value = parseDoubleText(text);
    if (value == null || (field != 'gain' && value <= 0)) return;
    if (field == 'q' && _bw) {
      value = bwToQ(value);
      if (value == null) return;
    }
    _model.applyField(field, value);
  }

  @override
  Widget build(BuildContext context) {
    // Field values update through their controllers; the section itself
    // only depends on these, so it doesn't rebuild on every drag step.
    return SelectBuilder(
      _changes,
      () => (
        _model.primary != null,
        _model.effectiveSelection.length,
        _model.primary?.type,
        _bw,
      ),
      (context) {
        final enabled = _model.primary != null;
        final count = _model.effectiveSelection.length;
        return Section(
          title: count > 1 ? 'Selected Filters ($count)' : 'Selected Filter',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NumberField(
                label: 'Frequency (Hz)',
                controller: _freq,
                enabled: enabled,
                step: 1,
                decimals: 0,
                min: 10,
                max: 30000,
                onChanged: (t) => _apply('freq', t),
              ),
              NumberField(
                label: 'Gain (dB)',
                controller: _gain,
                enabled: enabled,
                step: 0.1,
                decimals: 1,
                min: -30,
                max: 30,
                onChanged: (t) => _apply('gain', t),
              ),
              NumberField(
                label: _bw ? 'Bandwidth (oct)' : 'Q',
                controller: _q,
                enabled: enabled,
                step: 0.1,
                decimals: 1,
                min: 0.1,
                max: 100,
                onChanged: (t) => _apply('q', t),
              ),
              LabeledRow(
                label: 'Type',
                child: InputDecorator(
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.symmetric(horizontal: 8),
                  ),
                  isEmpty: false,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _type,
                      isExpanded: true,
                      isDense: !isTouchPlatform(context),
                      items: [
                        for (final t in filterTypes)
                          DropdownMenuItem(value: t, child: Text(t)),
                      ],
                      onChanged: enabled
                          ? (t) {
                              if (t == null) return;
                              _type = t;
                              _apply('type', t);
                            }
                          : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
