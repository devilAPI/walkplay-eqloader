/// Profile .txt format (EqualizerAPO / eq.hangout.audio).
library;

import 'band.dart';

const _txtTypeToInternal = {
  'LS': 'LSQ', 'LSC': 'LSQ', 'LSQ': 'LSQ', //
  'HS': 'HSQ', 'HSC': 'HSQ', 'HSQ': 'HSQ',
  'PK': 'PK', 'LP': 'LP', 'HP': 'HP',
};
const _internalTypeToTxt = {
  'LSQ': 'LS', 'HSQ': 'HS', 'PK': 'PK', 'LP': 'LP', 'HP': 'HP', //
};

final _preampRe = RegExp(
  r'^\s*Preamp:\s*([+-]?[\d.,]+)\s*dB',
  caseSensitive: false,
);
final _filterRe = RegExp(
  r'^\s*Filter\s+\d+:\s*'
  r'(ON|OFF)\s+'
  r'(\S+)\s+'
  r'Fc\s+([\d.,]+)\s*Hz\s+'
  r'Gain\s+([+-]?[\d.,]+)\s*dB\s+'
  r'Q\s+([\d.,]+)',
  caseSensitive: false,
);

double _toFloat(String text) => double.parse(text.trim().replaceAll(',', '.'));

String fmtNum(double value, int decimals) =>
    value.toStringAsFixed(decimals).replaceAll('.', ',');

class Profile {
  final double preamp;
  final List<Band> filters;
  const Profile(this.preamp, this.filters);
}

/// Parse profile text. OFF bands come back as inert bands flagged disabled.
Profile parseProfile(String text, {String source = 'profile'}) {
  var preamp = 0.0;
  final filters = <Band>[];

  for (final line in text.split(RegExp(r'\r?\n'))) {
    final pm = _preampRe.firstMatch(line);
    if (pm != null) {
      preamp = _toFloat(pm.group(1)!);
      continue;
    }
    final m = _filterRe.firstMatch(line);
    if (m == null) continue;

    if (m.group(1)!.toUpperCase() == 'OFF') {
      filters.add(inertFilter()..disabled = true);
      continue;
    }
    filters.add(
      Band(
        type: _txtTypeToInternal[m.group(2)!.toUpperCase()] ?? 'PK',
        freq: _toFloat(m.group(3)!),
        gain: _toFloat(m.group(4)!),
        q: _toFloat(m.group(5)!),
      ),
    );
  }

  if (filters.isEmpty) {
    throw FormatException("No 'Filter N: ...' lines found in $source");
  }
  return Profile(preamp, filters);
}

String formatProfile(double preamp, List<Band> filters) {
  final lines = ['Preamp: ${fmtNum(preamp, 1)} dB'];
  for (var i = 0; i < filters.length; i++) {
    final f = filters[i];
    final state = filterIsOff(f) ? 'OFF' : 'ON';
    final txtType = _internalTypeToTxt[f.type] ?? f.type;
    lines.add(
      'Filter ${i + 1}: $state $txtType '
      'Fc ${fmtNum(f.freq, 1)} Hz '
      'Gain ${fmtNum(f.gain, 1)} dB '
      'Q ${fmtNum(f.q, 3)}',
    );
  }
  return '${lines.join('\n')}\n';
}
