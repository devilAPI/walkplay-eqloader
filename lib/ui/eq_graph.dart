import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/band.dart';
import '../core/dsp.dart';
import '../state/eq_model.dart';
import '../state/settings.dart';
import 'theme.dart';

const graphGainLimit = 15.0; // dB; graph y-range and drag clamp
const _fMin = 20.0, _fMax = 20000.0;

/// Maps between plot coordinates and (freq, gain) for one widget size.
class _Axes {
  final Size size;
  final Rect plot;
  _Axes(this.size)
    : plot = Rect.fromLTRB(36, 24, size.width - 8, size.height - 20);

  static final _l0 = log10(_fMin), _l1 = log10(_fMax);

  bool get isEmpty => plot.width <= 0 || plot.height <= 0;

  double x(double f) =>
      plot.left + (log10(f.clamp(1, 1e6)) - _l0) / (_l1 - _l0) * plot.width;
  double y(double g) =>
      plot.top + (graphGainLimit - g) / (2 * graphGainLimit) * plot.height;
  double freqAt(double px) => math
      .pow(10, _l0 + (px - plot.left) / plot.width * (_l1 - _l0))
      .toDouble();
  double gainAt(double py) =>
      graphGainLimit - (py - plot.top) / plot.height * 2 * graphGainLimit;
}

/// Frequency-response graph with draggable band handles.
///
/// Click/tap empty space: add a band there (and drag it). Drag a handle: move
/// its frequency/gain. Right-click (mouse) or long-press (touch) a handle:
/// delete it.
///
/// The trace is the bands' summed response; the preamp shifts the whole
/// output, so the optional flat reference (what you hear with the EQ off) is
/// drawn at -preamp instead of shifting the trace off its handles. Where the
/// trace is above the reference, the EQ is louder than bypass.
///
/// Performance: the grid is its own cached layer that only repaints on
/// resize; the trace/handle layer repaints straight from [EqModel]
/// notifications without rebuilding widgets, and recomputes only the
/// response of bands that actually changed.
class EqGraph extends StatefulWidget {
  final EqModel model;
  final Settings settings;
  final Future<void> Function(int index) onDeleteRequest;

  const EqGraph({
    super.key,
    required this.model,
    required this.settings,
    required this.onDeleteRequest,
  });

  @override
  State<EqGraph> createState() => _EqGraphState();
}

class _EqGraphState extends State<EqGraph> {
  int? _dragIdx;
  bool _dragStarted = false;
  Offset _downPos = Offset.zero;
  Offset _grabOffset = Offset.zero; // handle centre minus pointer
  double _slop = 0;
  Timer? _longPress;
  _Axes? _axes;
  late final _TracePainter _tracePainter = _TracePainter(
    widget.model,
    widget.settings,
  );

  EqModel get model => widget.model;

  int _bandAt(_Axes axes, Offset pos, double maxPixels) {
    var best = -1;
    var bestDist = double.infinity;
    for (var i = 0; i < model.filters.length; i++) {
      final f = model.filters[i];
      final d = (Offset(axes.x(f.freq), axes.y(f.gain)) - pos).distance;
      if (d < bestDist) {
        best = i;
        bestDist = d;
      }
    }
    return bestDist <= maxPixels ? best : -1;
  }

  void _onDown(PointerDownEvent e) {
    final axes = _axes;
    if (axes == null || axes.isEmpty || !axes.plot.contains(e.localPosition)) {
      return;
    }
    final touch =
        e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus;
    final index = _bandAt(axes, e.localPosition, touch ? 28 : 14);

    if (e.buttons & kSecondaryMouseButton != 0) {
      if (index >= 0) widget.onDeleteRequest(index);
      return;
    }

    _downPos = e.localPosition;
    _slop = touch ? 6 : 0;
    if (index >= 0) {
      final f = model.filters[index];
      _grabOffset = Offset(axes.x(f.freq), axes.y(f.gain)) - e.localPosition;
      _dragStarted = false;
      model.beginDragExisting(index);
      if (touch) {
        _longPress = Timer(const Duration(milliseconds: 550), () {
          if (!_dragStarted && _dragIdx == index) {
            _endDrag();
            widget.onDeleteRequest(index);
          }
        });
      }
    } else {
      _grabOffset = Offset.zero;
      _dragStarted = true;
      model.beginDragNew(
        axes.freqAt(e.localPosition.dx),
        axes.gainAt(e.localPosition.dy).clamp(-graphGainLimit, graphGainLimit),
      );
    }
    _dragIdx = model.selected;
  }

  void _onMove(PointerMoveEvent e) {
    final idx = _dragIdx;
    final axes = _axes;
    if (idx == null || axes == null) return;
    if (!_dragStarted) {
      if ((e.localPosition - _downPos).distance <= _slop) return;
      _dragStarted = true;
      _longPress?.cancel();
    }
    final p = e.localPosition + _grabOffset;
    model.dragTo(
      idx,
      axes.freqAt(p.dx).clamp(_fMin, _fMax),
      axes.gainAt(p.dy).clamp(-graphGainLimit, graphGainLimit),
    );
  }

  void _endDrag() {
    _longPress?.cancel();
    _longPress = null;
    if (_dragIdx != null) {
      _dragIdx = null;
      model.endDrag();
    }
  }

  @override
  void dispose() {
    _longPress?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (_axes?.size != size) _axes = _Axes(size);
        final axes = _axes!;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: (_) => _endDrag(),
          onPointerCancel: (_) => _endDrag(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(child: CustomPaint(painter: _GridPainter(axes))),
              RepaintBoundary(
                child: CustomPaint(painter: _tracePainter..axes = axes),
              ),
              Positioned(
                top: 0,
                right: 4,
                height: axes.plot.top,
                child: _FlatToggle(widget.settings),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

TextPainter _label(
  String s, {
  Color color = Palette.muted,
  double size = 10,
  bool bold = false,
}) => TextPainter(
  text: TextSpan(
    text: s,
    style: TextStyle(
      color: color,
      fontSize: size,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    ),
  ),
  textDirection: TextDirection.ltr,
)..layout();

void _paintLabel(Canvas canvas, TextPainter tp, Offset at, Alignment align) {
  tp.paint(
    canvas,
    Offset(
      at.dx - tp.width * (align.x + 1) / 2,
      at.dy - tp.height * (align.y + 1) / 2,
    ),
  );
}

/// Static background: frame, grid and axis labels. Repaints only on resize.
class _GridPainter extends CustomPainter {
  final _Axes axes;
  _GridPainter(this.axes);

  static const _majorFreqs = [20.0, 100.0, 1000.0, 10000.0, 20000.0];
  static final _freqLabels = [
    for (final f in _majorFreqs)
      _label(f >= 1000 ? '${f ~/ 1000} kHz' : '${f.toInt()} Hz'),
  ];
  static final _gainLabels = {
    for (var g = -graphGainLimit; g <= graphGainLimit; g += 5)
      g: _label(g.toInt().toString()),
  };
  static final _title = _label('EQ RESPONSE', bold: true, size: 11);
  static final _unit = _label('dB', size: 9);

  static final _bg = Paint()..color = Palette.chassis;
  static final _panel = Paint()..color = Palette.panel;
  static final _major = Paint()
    ..color = Palette.line
    ..strokeWidth = 0.8;
  static final _minor = Paint()
    ..color = Palette.line.withValues(alpha: 0.5)
    ..strokeWidth = 0.5;
  static final _zero = Paint()
    ..color = Palette.muted.withValues(alpha: 0.6)
    ..strokeWidth = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _bg);
    if (axes.isEmpty) return;
    final plot = axes.plot;
    canvas.drawRect(plot, _panel);

    for (var decade = 10.0; decade <= 10000; decade *= 10) {
      for (var m = 2; m <= 9; m++) {
        final f = decade * m;
        if (f <= _fMin || f >= _fMax) continue;
        final x = axes.x(f);
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), _minor);
      }
    }
    for (var i = 0; i < _majorFreqs.length; i++) {
      final f = _majorFreqs[i];
      final x = axes.x(f);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), _major);
      _paintLabel(
        canvas,
        _freqLabels[i],
        Offset(x, plot.bottom + 4),
        f == _fMin
            ? Alignment.topLeft
            : (f == _fMax ? Alignment.topRight : Alignment.topCenter),
      );
    }
    for (final MapEntry(key: g, value: tp) in _gainLabels.entries) {
      final y = axes.y(g);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), _major);
      _paintLabel(canvas, tp, Offset(plot.left - 5, y), Alignment.centerRight);
    }
    canvas.drawLine(
      Offset(plot.left, axes.y(0)),
      Offset(plot.right, axes.y(0)),
      _zero,
    );
    _paintLabel(canvas, _title, Offset(plot.left, 12), Alignment.centerLeft);
    _paintLabel(
      canvas,
      _unit,
      Offset(plot.left - 5, 12),
      Alignment.centerRight,
    );
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.axes.size != axes.size;
}

/// Summed response of a band list, recomputing only bands whose parameters
/// changed since the last call (a drag touches one band per frame).
class _ResponseCache {
  static const points = 360;
  static final freqs = [
    for (var i = 0; i < points; i++)
      math
          .pow(
            10,
            log10(_fMin) + i / (points - 1) * (log10(_fMax) - log10(_fMin)),
          )
          .toDouble(),
  ];
  static final _phi = biquadPhi(freqs, deviceSampleRate);

  final _keys = <(String, double, double, double)>[];
  final _parts = <Float64List>[];
  final sum = Float64List(points);

  /// Update for [filters]; returns true when the summed response changed.
  bool update(List<Band> filters) {
    var changed = filters.length != _keys.length;
    if (_keys.length > filters.length) {
      _keys.length = filters.length;
      _parts.length = filters.length;
    }
    for (var i = 0; i < filters.length; i++) {
      final f = filters[i];
      final key = (f.type, f.freq, f.gain, f.q);
      if (i < _keys.length && _keys[i] == key) continue;
      final c = biquadCoeffs(f.type, f.freq, f.gain, f.q);
      final part = c == null ? Float64List(points) : gainsDb(_phi, [c]);
      if (i < _keys.length) {
        _keys[i] = key;
        _parts[i] = part;
      } else {
        _keys.add(key);
        _parts.add(part);
      }
      changed = true;
    }
    if (changed) {
      sum.fillRange(0, points, 0);
      for (final part in _parts) {
        for (var k = 0; k < points; k++) {
          sum[k] += part[k];
        }
      }
    }
    return changed;
  }
}

/// Response trace, flat reference and band handles; repaints directly on
/// model and settings changes.
class _TracePainter extends CustomPainter {
  final EqModel model;
  final Settings settings;
  _Axes? axes;
  _TracePainter(this.model, this.settings)
    : super(repaint: Listenable.merge([model.graph, settings]));

  final _cache = _ResponseCache();
  Path? _trace, _fill;
  _Axes? _pathAxes;
  Float64List? _xs; // pixel x of each response point, per size

  static final _fillPaint = Paint()
    ..color = Palette.accent.withValues(alpha: 0.10);
  static final _glowPaint = Paint()
    ..color = Palette.accent.withValues(alpha: 0.16)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5
    ..strokeJoin = StrokeJoin.round;
  static final _tracePaint = Paint()
    ..color = Palette.accent
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeJoin = StrokeJoin.round;
  static final _halo = Paint()..color = Palette.active.withValues(alpha: 0.25);
  static final _ring = Paint()..color = Palette.chassis;
  static final _dotActive = Paint()..color = Palette.active;
  static final _dotIdle = Paint()..color = Palette.accent;
  static final _numbers = <(int, bool), TextPainter>{};
  static final _reference = Paint()
    ..color = Palette.ink.withValues(alpha: 0.55)
    ..strokeWidth = 1.2;
  static final _referenceLabel = _label('FLAT', size: 9, bold: true);

  static TextPainter _number(int n, bool hi) => _numbers.putIfAbsent((
    n,
    hi,
  ), () => _label('$n', size: 9, color: hi ? Palette.active : Palette.muted));

  void _rebuildPaths(_Axes axes) {
    if (_xs == null || !identical(_pathAxes, axes)) {
      _xs = Float64List.fromList([
        for (final f in _ResponseCache.freqs) axes.x(f),
      ]);
    }
    _pathAxes = axes;
    final xs = _xs!;
    final sum = _cache.sum;
    final trace = Path()..moveTo(xs[0], axes.y(sum[0]));
    for (var i = 1; i < xs.length; i++) {
      trace.lineTo(xs[i], axes.y(sum[i]));
    }
    _trace = trace;
    _fill = Path.from(trace)
      ..lineTo(xs.last, axes.y(0))
      ..lineTo(xs.first, axes.y(0))
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final axes = this.axes;
    if (axes == null || axes.isEmpty) return;
    final responseChanged = _cache.update(model.filters);
    if (responseChanged || _trace == null || !identical(_pathAxes, axes)) {
      _rebuildPaths(axes);
    }

    canvas.save();
    canvas.clipRect(axes.plot);
    if (settings.showFlatReference) _paintReference(canvas, axes);
    canvas.drawPath(_fill!, _fillPaint);
    canvas.drawPath(_trace!, _glowPaint);
    canvas.drawPath(_trace!, _tracePaint);

    final highlighted = model.highlighted;
    for (var i = 0; i < model.filters.length; i++) {
      final f = model.filters[i];
      final c = Offset(axes.x(f.freq), axes.y(f.gain));
      final hi = highlighted.contains(i);
      if (hi) canvas.drawCircle(c, 11, _halo);
      canvas.drawCircle(c, 6, _ring);
      canvas.drawCircle(c, 4.8, hi ? _dotActive : _dotIdle);
      _paintLabel(
        canvas,
        _number(i + 1, hi),
        c + const Offset(0, -15),
        Alignment.center,
      );
    }
    canvas.restore();
  }

  /// Dashed line where the output equals the bypassed (EQ off) level.
  void _paintReference(Canvas canvas, _Axes axes) {
    final y = axes.y(flatReferenceGain(model.preampDb));
    const dash = 6.0, gap = 4.0;
    for (var x = axes.plot.left; x < axes.plot.right; x += dash + gap) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dash, axes.plot.right), y),
        _reference,
      );
    }
    _paintLabel(
      canvas,
      _referenceLabel,
      Offset(axes.plot.right - 4, y - 3),
      Alignment.bottomRight,
    );
  }

  @override
  bool shouldRepaint(covariant _TracePainter old) => true;
}

/// Graph gain (band dB scale) at which the output equals the bypassed level.
double flatReferenceGain(double preampDb) => -preampDb;

/// Header switch for the flat reference line.
class _FlatToggle extends StatelessWidget {
  final Settings settings;
  const _FlatToggle(this.settings);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) {
      final on = settings.showFlatReference;
      return Tooltip(
        message: on
            ? 'Hide the flat reference (EQ off, shifted by the preamp)'
            : 'Show the flat reference (EQ off, shifted by the preamp)',
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: on ? Palette.ink : Palette.muted,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          icon: Icon(
            on ? Icons.check_box_outlined : Icons.check_box_outline_blank,
            size: 14,
          ),
          label: const Text('FLAT'),
          onPressed: () => settings.update(showFlatReference: !on),
        ),
      );
    },
  );
}
