// Export sizes, as the Mac app offers them (web/src/export-sizes.js): the full picture, then
// Large, Medium and Small at 75, 50 and 25 per cent of it where that is still a useful picture,
// then the long edges the web editor has always offered. An id is "full", a fraction ("0.75") or
// a long edge in pixels ("3840"). The desktop engine measures a size's long edge on the cropped
// picture and rounds outward (`longEdgeOfCrop`), so these do too.
import 'dart:math' as math;

typedef PixelSize = ({int width, int height});

class ExportSize {
  const ExportSize(this.id, this.label, {this.detail, this.pixels});
  final String id, label;

  /// What it delivers, as the picker shows it: "3000 × 2000", or "75%" across photographs.
  final String? detail;
  final PixelSize? pixels;
}

const _fractions = [('Large', .75), ('Medium', .5), ('Small', .25)];
const _stillEdges = [3840, 2048, 1600];

/// The size of the picture a crop (four corners in unit coordinates) cuts from a `width` x
/// `height` one (geometry.js `outputSize`).
PixelSize outputSize(List crop, int width, int height) {
  double distance(List a, List b) => math.sqrt(
      math.pow(((a[0] as num) - (b[0] as num)) * width, 2) +
          math.pow(((a[1] as num) - (b[1] as num)) * height, 2));
  return (
    width: math.max(1, ((distance(crop[0], crop[1]) + distance(crop[3], crop[2])) / 2).round()),
    height: math.max(1, ((distance(crop[0], crop[3]) + distance(crop[1], crop[2])) / 2).round()),
  );
}

/// The pixels of `output` (the cropped picture) an export whose long edge is `edge` delivers,
/// the edge measured on the cropped picture and rounded outward.
PixelSize exportPixels(num edge, PixelSize output) {
  final long = math.max(output.width, output.height);
  if (!(edge < long - .5)) return output;
  int outward(int length) => math.max(1, (length * edge / long - 1e-6).ceil());
  return (width: outward(output.width), height: outward(output.height));
}

/// The sizes one photograph offers, each naming the pixels it delivers of `output`, its
/// cropped picture.
List<ExportSize> exportSizeOptions(PixelSize output) {
  final long = math.max(output.width, output.height);
  ExportSize size(String id, String label, num edge) {
    final pixels = exportPixels(edge, output);
    return ExportSize(id, label, detail: '${pixels.width} × ${pixels.height}', pixels: pixels);
  }

  if (long <= 0) return const [ExportSize('full', 'Full resolution')];
  final options = [size('full', 'Full resolution', long)];
  for (final (label, fraction) in _fractions) {
    final edge = (long * fraction).round();
    if (edge >= 640 && edge < long - 1) options.add(size('$fraction', label, edge));
  }
  for (final edge in _stillEdges) {
    if (edge < long - 1) options.add(size('$edge', '$edge px long edge', edge));
  }
  return options;
}

/// The sizes Export All offers, the same ids as one photograph's, each applied to every
/// photograph's own cropped picture.
List<ExportSize> batchExportSizeOptions() => [
      const ExportSize('full', 'Full resolution'),
      for (final (label, fraction) in _fractions)
        ExportSize('$fraction', label, detail: '${(fraction * 100).round()}%'),
      for (final edge in _stillEdges) ExportSize('$edge', '$edge px long edge'),
    ];

/// The long edge an export size asks for of the cropped picture, null for the whole of it.
int? exportMaxEdge(String size, PixelSize output) {
  final value = double.tryParse(size);
  if (size == 'full' || value == null || !value.isFinite || value <= 0) return null;
  return value < 1 ? (math.max(output.width, output.height) * value).round() : value.round();
}

/// The Mac app's note when the full picture exceeds the engine's memory limit (`unavailable`
/// ids): which smaller size stands in, or that none can. Null when the full picture fits.
String? resolutionLimitWarning(List<ExportSize> sizes, String selected, List<String> unavailable) {
  if (!unavailable.contains('full')) return null;
  final size =
      sizes.where((s) => s.id == selected && !unavailable.contains(s.id)).firstOrNull;
  if (size == null) {
    return 'Resolution unavailable: This image exceeds this device’s safe memory limit at '
        'every export size.';
  }
  return 'Resolution reduced: Full resolution exceeds this device’s safe memory limit. '
      '${size.label} (${size.detail}) is selected instead, so the export will contain fewer '
      'pixels.';
}
