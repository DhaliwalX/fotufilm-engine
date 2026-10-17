// The histogram of the developed picture, measured as the web editor's analyser does
// (web/src/histogram-model.js): the preview reduced to a 256-pixel long edge, transparent pixels
// skipped, 256 bins for each channel and for luma.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

class HistogramData {
  HistogramData(this.red, this.green, this.blue, this.luma, this.count);
  final Uint32List red, green, blue, luma;
  final int count;

  static Future<HistogramData?> measure(ui.Image image) async {
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
    return compute(_bin, data.buffer.asUint8List());
  }

  static HistogramData _bin(Uint8List rgba) {
    final r = Uint32List(256), g = Uint32List(256), b = Uint32List(256), y = Uint32List(256);
    var count = 0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] == 0) continue;
      final pr = rgba[i], pg = rgba[i + 1], pb = rgba[i + 2];
      r[pr]++;
      g[pg]++;
      b[pb]++;
      // Display P3's luminance weights.
      y[(0.2290 * pr + 0.6917 * pg + 0.0793 * pb).round().clamp(0, 255)]++;
      count++;
    }
    return HistogramData(r, g, b, y, count);
  }
}
