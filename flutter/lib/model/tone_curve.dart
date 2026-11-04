// The Output panel's tone curve: the shown photograph's edit developed over a neutral grey ramp by
// the engine (`toneCurve`), as the Display P3 codes the preview shows, with the photograph's own
// tones binned on the same input axis behind it.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import 'editor.dart';

class ToneCurveData {
  ToneCurveData({required this.red, required this.green, required this.blue,
      required this.histogram});

  /// The output of each input code 0…255, 0…1 per channel.
  final List<double> red, green, blue;

  /// The photograph's pixels at each input code, by luma.
  final List<int> histogram;

  static ToneCurveData? from(Object? value) {
    if (value is! Map) return null;
    List<double>? curve(String key) =>
        (value[key] as List?)?.map((v) => (v as num).toDouble()).toList();
    final red = curve('red'), green = curve('green'), blue = curve('blue');
    final histogram = (value['histogram'] as List?)?.map((v) => (v as num).toInt()).toList();
    if (red == null || green == null || blue == null || histogram == null) return null;
    return ToneCurveData(red: red, green: green, blue: blue, histogram: histogram);
  }
}

class ToneCurve extends ChangeNotifier {
  ToneCurve(this.editor);
  final EditorModel editor;

  /// How long the edit has to hold still before the curve is asked for: a slider drag develops
  /// many pictures, and the curve follows the one it settles on.
  static const settle = Duration(milliseconds: 200);

  ToneCurveData? _curve;
  String? _key, _pendingKey;
  Timer? _timer;

  /// Whether this engine charts curves at all; the browser's does not.
  bool _answers = true;

  /// The curve of the picture last shown, or null while there is none to chart: no film, a
  /// scanned negative, or an engine that does not chart.
  ToneCurveData? get curve => _answers ? _curve : null;

  /// Asks the engine for the shown picture's curve once its develop request has settled.
  void follow() {
    final request = editor.active?.shownRequest, engine = editor.engine;
    if (!_answers || request == null || engine == null) return;
    final key = jsonEncode(request);
    if (key == _key || key == _pendingKey) return;
    _pendingKey = key;
    _timer?.cancel();
    _timer = Timer(settle, () {
      if (_pendingKey != key) return;
      engine.call('toneCurve', {'render': request}).then((answer) {
        if (_pendingKey != key) return;
        _settle(key, ToneCurveData.from(answer.value));
      }, onError: (Object e) {
        if (_pendingKey != key) return;
        _pendingKey = null;
        // A newer develop cancelled this one; the next settle asks again.
        if (e is FotufilmCancelled) return;
        // The browser engine answers no curve (flutter-bridge.js names the method it lacks).
        if (e is FotufilmException && e.message.contains('does not answer')) _answers = false;
        _settle(key, null);
      });
    });
  }

  void _settle(String key, ToneCurveData? curve) {
    _key = key;
    _pendingKey = null;
    _curve = curve;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
