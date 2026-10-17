import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/export.dart';

void main() {
  group('export sizes (export-sizes.js)', () {
    test('a 6000 x 4000 picture offers the Mac app sizes', () {
      final sizes = exportSizeOptions((width: 6000, height: 4000));
      expect(sizes.map((s) => s.id),
          ['full', '0.75', '0.5', '0.25', '3840', '2048', '1600']);
      expect(sizes.first.label, 'Full resolution');
      expect(sizes.first.detail, '6000 × 4000');
      expect(sizes[1].label, 'Large');
      expect(sizes[1].detail, '4500 × 3000');
      expect(sizes[4].detail, '3840 × 2560');
    });

    test('a small picture leaves out fractions under 640 px and edges past its own', () {
      final sizes = exportSizeOptions((width: 2000, height: 1000));
      expect(sizes.map((s) => s.id), ['full', '0.75', '0.5', '1600']);
    });

    test('pixels round outward on the cropped picture', () {
      expect(exportPixels(1000, (width: 3001, height: 2000)), (width: 1000, height: 667));
      expect(exportPixels(5000, (width: 3000, height: 2000)), (width: 3000, height: 2000));
    });

    test('the long edge a size asks for', () {
      const crop = (width: 6000, height: 4000);
      expect(exportMaxEdge('full', crop), isNull);
      expect(exportMaxEdge('0.5', crop), 3000);
      expect(exportMaxEdge('2048', crop), 2048);
      expect(exportMaxEdge('nonsense', crop), isNull);
    });

    test('Export All sizes name percentages', () {
      final sizes = batchExportSizeOptions();
      expect(sizes.map((s) => s.id), ['full', '0.75', '0.5', '0.25', '3840', '2048', '1600']);
      expect(sizes[1].detail, '75%');
    });

    test('the memory limit note', () {
      final sizes = exportSizeOptions((width: 6000, height: 4000));
      expect(resolutionLimitWarning(sizes, 'full', const []), isNull);
      expect(resolutionLimitWarning(sizes, '0.75', const ['full']),
          contains('Large (4500 × 3000) is selected instead'));
      expect(resolutionLimitWarning(sizes, 'full', const ['full']),
          startsWith('Resolution unavailable'));
    });

    test('a crop measures its corners', () {
      const half = [
        [0.0, 0.0],
        [0.5, 0.0],
        [0.5, 1.0],
        [0.0, 1.0],
      ];
      expect(outputSize(half, 6000, 4000), (width: 3000, height: 4000));
    });
  });

  group('file names (useExportActions.js)', () {
    test('a still is named for its photograph, film and medium', () {
      expect(stillFilename('IMG 0001.ARW', {'stock': 'gold200', 'medium': null}, 'image/jpeg'),
          'IMG-0001-gold200.jpg');
      expect(stillFilename('a.png', {'stock': null, 'medium': 'endura'}, 'image/tiff'),
          'a-normal-endura.tiff');
      expect(stillFilename('Été.heic', {'stock': 'portra400'}, 'image/heic'), 'Été-portra400.heic');
    });

    test('a name with nothing left is a photo', () {
      expect(cleanName('.png'), 'photo');
    });
  });
}
