import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/engine/engine.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/edit.dart';
import 'package:fotufilm_flutter/model/editor.dart';
import 'package:fotufilm_flutter/model/histogram.dart';
import 'package:fotufilm_flutter/model/tone_curve.dart';
import 'package:fotufilm_flutter/ui/inspector/tone_curve_chart.dart';

final _ramp = [for (var i = 0; i < 256; i++) i / 255];

/// An engine that charts every edit as a straight line.
class _Engine implements EngineConnection {
  @override
  Future<EngineReply> call(String method,
          [Map<String, dynamic> params = const {}, Uint8List? payload]) async =>
      EngineReply(
          method == 'toneCurve' ? {'red': _ramp, 'green': _ramp, 'blue': _ramp} : <String, dynamic>{},
          null);

  @override
  Future<EngineReply> callWithProgress(String method, Map<String, dynamic> params,
          void Function(Map<String, dynamic> progress) onProgress) =>
      call(method, params);

  @override
  Future<EngineReply> callInBackground(String method, Map<String, dynamic> params,
          [void Function(Map<String, dynamic> progress)? onProgress]) =>
      call(method, params);

  @override
  void cancel() {}
  @override
  void cancelBackground() {}
  @override
  Future<EngineReply> callAside(String method, Map<String, dynamic> params) =>
      call(method, params);
  @override
  bool get exportsInBackground => false;
  @override
  Map<String, dynamic> get capabilities => const {};
  @override
  int? get address => null;
  @override
  bool get picturesAreDisplayP3 => true;
  @override
  bool get opensPaths => true;
}

void main() {
  test('the engine curve reads per channel', () {
    final curve = ToneCurveData.from({'red': _ramp, 'green': _ramp, 'blue': _ramp})!;
    expect(curve.red.length, 256);
    expect(curve.green.last, 1.0);
  });

  test('no curve reads as none', () {
    expect(ToneCurveData.from(null), isNull);
    expect(ToneCurveData.from({'red': [0.0]}), isNull);
  });

  testWidgets('the chart draws the developed picture\'s tones, and they are measured for it',
      (tester) async {
    final catalogue = (await tester.runAsync(Catalogue.load))!;
    final editor = EditorModel(catalogue)..engine = _Engine();
    editor.documents.add(PhotoDocument(
        path: '/a.png',
        handle: 1,
        width: 600,
        height: 400,
        history: History(copyEdit(defaultEdit(catalogue))..['stock'] = 'gold200'))
      ..shownRequest = {'handle': 1});
    editor.activeIndex = 0;
    expect(editor.histogramShown, isFalse);

    Widget chart() => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: SizedBox(width: 280, child: ToneCurveChart(editor: editor))));
    ToneCurvePainter painter() =>
        tester.widget<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is ToneCurvePainter)).painter! as ToneCurvePainter;

    await tester.pumpWidget(chart());
    expect(editor.histogramShown, isFalse, reason: 'no curve is charted yet');
    await tester.pump(ToneCurve.settle);
    await tester.pump();
    expect(editor.histogramShown, isTrue, reason: 'the renderer measures while it is charted');
    expect(painter().tones, isNull);

    // The renderer's measurement of one picture, then of the next edit's.
    HistogramData measured(int code) =>
        HistogramData(List.generate(9, (_) => Uint32List(256)..[code] = 100), 100);
    final first = measured(40);
    editor.measured(first);
    await tester.pump();
    expect(painter().tones, same(first.luma));
    final brighter = measured(200);
    editor.measured(brighter);
    await tester.pump();
    expect(painter().tones, same(brighter.luma));
    expect(painter().shouldRepaint(ToneCurvePainter(
            curve: painter().curve,
            tones: first.luma,
            palette: painter().palette,
            colors: painter().colors,
            labelStyle: painter().labelStyle)),
        isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(editor.histogramShown, isFalse, reason: 'nothing draws the tones once it is gone');
  });
}
