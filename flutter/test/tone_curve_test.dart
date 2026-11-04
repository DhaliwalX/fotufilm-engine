import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/tone_curve.dart';

void main() {
  test('the engine curve reads per channel with the photograph histogram', () {
    final ramp = [for (var i = 0; i < 256; i++) i / 255];
    final curve = ToneCurveData.from({
      'red': ramp,
      'green': ramp,
      'blue': ramp,
      'histogram': [for (var i = 0; i < 256; i++) i],
    })!;
    expect(curve.red.length, 256);
    expect(curve.green.last, 1.0);
    expect(curve.histogram[10], 10);
  });

  test('no curve reads as none', () {
    expect(ToneCurveData.from(null), isNull);
    expect(ToneCurveData.from({'red': [0.0]}), isNull);
  });
}
