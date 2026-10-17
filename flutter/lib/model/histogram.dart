// The histogram of the developed picture, measured as the web editor's analyser does
// (web/src/histogram-model.js, histogram-color.js): the preview reduced to a 256-pixel long edge,
// transparent pixels skipped, 256 bins for red, green, blue, luma, the two chroma differences and
// OKLab's L, a and b. What each view plots, and how its count axis reads, follows
// web/src/histogram-views.js and histogram-curves.js.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

class HistogramData {
  HistogramData(this.channels, this.count);

  /// Red, green, blue, luma, Cb, Cr, OKLab L, a and b (`histogramPalette`'s order).
  final List<Uint32List> channels;
  final int count;

  Uint32List get red => channels[0];
  Uint32List get green => channels[1];
  Uint32List get blue => channels[2];
  Uint32List get luma => channels[3];

  /// `image`'s counts, in its own RGB space: Display P3 from the desktop engine, else sRGB.
  static Future<HistogramData?> measure(ui.Image image, {bool displayP3 = true}) async {
    const edge = 256;
    final scale = edge / (image.width > image.height ? image.width : image.height);
    final w = (image.width * scale).round().clamp(1, edge);
    final h = (image.height * scale).round().clamp(1, edge);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final small = await recorder.endRecording().toImage(w, h);
    final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    small.dispose();
    if (data == null) return null;
    return compute(_bin, (data.buffer.asUint8List(), displayP3));
  }

  static HistogramData _bin((Uint8List, bool) input) => statistics(input.$1, displayP3: input.$2);

  /// `histogramStatistics`: the counts of RGBA pixels.
  static HistogramData statistics(Uint8List rgba, {bool displayP3 = true}) {
    final channels = List.generate(9, (_) => Uint32List(256));
    // Luma's weights from the engine's Rec. 2020 luminance through the preview's primaries.
    final matrix = displayP3 ? _p3To2020 : _srgbTo2020;
    final weights = [
      for (var c = 0; c < 3; c++)
        [for (var r = 0; r < 3; r++) _luminance[r] * matrix[r * 3 + c]].reduce((a, b) => a + b),
    ];
    final total = weights.reduce((a, b) => a + b);
    final kr = weights[0] / total, kb = weights[2] / total;
    int bin(double v) => v.round().clamp(0, 255);
    // Numerical residue around the neutral axis reads as exactly zero.
    int opponent(double v) => v.abs() < 1e-7 ? 128 : bin((v / 0.8 + 0.5) * 255);
    final lms = displayP3 ? _p3ToLms : _srgbToLms;
    var count = 0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] == 0) continue;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      channels[0][r]++;
      channels[1][g]++;
      channels[2][b]++;
      final y = g + kr * (r - g) + kb * (b - g);
      channels[3][bin(y)]++;
      // Full-range colour differences, neutral at bin 128 (BT.709's construction on the
      // preview's primaries, of encoded signals).
      channels[4][bin(127.5 + (b - y) / (2 * (1 - kb)))]++;
      channels[5][bin(127.5 + (r - y) / (2 * (1 - kr)))]++;
      final (l, a, ob) = _okLab(r, g, b, lms);
      channels[6][bin(l * 255)]++;
      channels[7][opponent(a)]++;
      channels[8][opponent(ob)]++;
      count++;
    }
    return HistogramData(channels, count);
  }

  // engine-constants.js INGEST_COLOR.
  static const _srgbTo2020 = [
    0.627403896, 0.329283038, 0.043313066, 0.069097289, 0.919540395, 0.011362316, //
    0.016391439, 0.088013308, 0.895595253,
  ];
  static const _p3To2020 = [
    0.753833034, 0.198597369, 0.047569597, 0.045743849, 0.94177722, 0.012478931, //
    -0.00121034, 0.017601717, 0.983608623,
  ];
  static const _luminance = [0.2627002, 0.6779981, 0.0593017];

  // histogram-color.js: D65 matrices and OKLab after the CSS Color 4 sample code.
  static const _xyzToLms = [
    [0.819022437996703, 0.3619062600528904, -0.1288737815209879],
    [0.0329836539323885, 0.9292868615863434, 0.0361446663506424],
    [0.0481771893596242, 0.2642395317527308, 0.6335478284694309],
  ];
  static const _srgbToXyz = [
    [506752 / 1228815, 87881 / 245763, 12673 / 70218],
    [87098 / 409605, 175762 / 245763, 12673 / 175545],
    [7918 / 409605, 87881 / 737289, 1001167 / 1053270],
  ];
  static const _p3ToXyz = [
    [608311 / 1250200, 189793 / 714400, 198249 / 1000160],
    [35783 / 156275, 247089 / 357200, 198249 / 2500400],
    [0.0, 32229 / 714400, 5220557 / 5000800],
  ];
  static List<List<double>> _toLms(List<List<double>> rgbToXyz) => [
        for (final row in _xyzToLms)
          [
            for (var c = 0; c < 3; c++)
              row[0] * rgbToXyz[0][c] + row[1] * rgbToXyz[1][c] + row[2] * rgbToXyz[2][c],
          ],
      ];
  static final _srgbToLms = _toLms(_srgbToXyz);
  static final _p3ToLms = _toLms(_p3ToXyz);

  // Both display spaces use the sRGB transfer function; decode before OKLab.
  static final _linear = Float64List.fromList([
    for (var i = 0; i < 256; i++)
      i / 255 <= 0.04045 ? i / 255 / 12.92 : math.pow((i / 255 + 0.055) / 1.055, 2.4).toDouble(),
  ]);

  static double _cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();

  static (double, double, double) _okLab(int r, int g, int b, List<List<double>> m) {
    final rr = _linear[r], gg = _linear[g], bb = _linear[b];
    final l = _cbrt(m[0][0] * rr + m[0][1] * gg + m[0][2] * bb);
    final mm = _cbrt(m[1][0] * rr + m[1][1] * gg + m[1][2] * bb);
    final s = _cbrt(m[2][0] * rr + m[2][1] * gg + m[2][2] * bb);
    return (
      0.210454268309314 * l + 0.7936177747023054 * mm - 0.0040720430116193 * s,
      1.9779985324311684 * l - 2.42859224204858 * mm + 0.450593709617411 * s,
      0.0259040424655478 * l + 0.7827717124575296 * mm - 0.8086757549230774 * s,
    );
  }
}

/// A histogram view: the channels it plots, its legend (label and colour name) and the ticks
/// under it (histogram-views.js).
class HistogramView {
  const HistogramView(this.id, this.channels, this.description, this.legend, this.ticks,
      {this.centered = false});
  final String id;
  final List<int> channels;
  final String description;
  final List<(String, String)> legend;
  final List<String> ticks;

  /// Whether zero is in the middle (a dashed line marks it).
  final bool centered;

  static const all = {
    'rgb': HistogramView('rgb', [0, 1, 2], 'Red, green and blue tonal distribution',
        [('RGB', 'luma')], ['0', '64', '128', '192', '255']),
    'luma': HistogramView('luma', [3], 'Luma brightness distribution', [('Luma Y′', 'luma')],
        ['0', '64', '128', '192', '255']),
    'chroma': HistogramView('chroma', [4, 5], 'Chroma Cb and Cr color-difference distribution',
        [('Cb', 'blue'), ('Cr', 'red')], ['−0.5', '−0.25', '0', '+0.25', '+0.5'],
        centered: true),
    'oklab-l': HistogramView('oklab-l', [6], 'OKLab perceptual lightness distribution',
        [('Lightness L', 'luma')], ['0', '0.25', '0.5', '0.75', '1']),
    'oklab-ab': HistogramView('oklab-ab', [7, 8], 'OKLab a and b color-balance distribution',
        [('a · green–red', 'a'), ('b · blue–yellow', 'b')], ['−0.4', '−0.2', '0', '+0.2', '+0.4'],
        centered: true),
  };
}

/// Each channel's colour name, in `HistogramData.channels`' order.
const histogramPalette = ['red', 'green', 'blue', 'luma', 'blue', 'red', 'luma', 'a', 'b'];

/// Two narrow binomial passes soften sampling noise without changing raw counts; the edges
/// reflect, conserving mass and keeping the black and white endpoint peaks.
List<double> smoothHistogram(List<num> values) {
  var current = [for (final v in values) v.toDouble()];
  const weights = [1, 4, 6, 4, 1];
  for (var pass = 0; pass < 2; pass++) {
    final source = current;
    current = List.generate(source.length, (i) {
      var sum = 0.0;
      for (var k = 0; k < weights.length; k++) {
        var index = i + k - 2;
        while (index < 0 || index >= source.length) {
          index = index < 0 ? -index - 1 : 2 * source.length - index - 1;
        }
        sum += source[index] * weights[k] / 16;
      }
      return sum;
    });
  }
  return current;
}

/// The count axis: limits rounded upward so it reads 10 / 100 / 1k, not arbitrary peaks.
({double max, List<double> ticks}) histogramCountAxis(double peak, {required bool log}) {
  peak = math.max(1, peak);
  if (log) {
    final max = math.pow(10, (math.log(peak) / math.ln10).ceil()).toDouble();
    final ticks = <double>[0];
    for (var n = 1.0; n <= max; n *= 10) {
      ticks.add(n);
    }
    return (max: max, ticks: ticks);
  }
  final magnitude = math.pow(10, (math.log(peak / 4) / math.ln10).floor()).toDouble();
  final step = math.max(
      1.0, [1, 2, 5, 10].firstWhere((n) => n * magnitude >= peak / 4, orElse: () => 10) * magnitude);
  final max = (peak / step).ceil() * step;
  return (max: max, ticks: [for (var i = 0; i <= (max / step).round(); i++) i * step]);
}

/// A count's height on the axis, 0 to 1.
double histogramCountHeight(double count, double max, {required bool log}) =>
    log ? math.log(1 + count) / math.log(1 + max) : count / max;

/// An axis tick as the plot labels it: 250, 1.5k.
String histogramTickLabel(double count) {
  if (count >= 1000) {
    final k = (count / 1000).toStringAsFixed(1);
    return '${k.endsWith('.0') ? k.substring(0, k.length - 2) : k}k';
  }
  return '${count.round()}';
}
