import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/band_sets.dart';
import 'package:fotufilm_flutter/model/lens.dart';
import 'package:fotufilm_flutter/model/lens_filters.dart';
import 'package:fotufilm_flutter/model/print_frame.dart';

void main() {
  group('lens filters', () {
    final catalogue = LensFilterCatalogue({
      'choices': [
        {'id': 'w81a', 'name': '81A', 'spectrum': [[1, 2, 3], [4, 5, 6]]},
        {'id': 'promist-1/4', 'name': 'Pro-Mist 1/4'},
      ],
      'meterings': [
        {'id': 'throughTheLens', 'name': 'Metered through'},
      ],
      'supported': ['w81a', 'w85c', 'promist-1/4', 'fog-1'],
      'names': {'w85c': '85C'},
    });

    test('diffusion filters scatter, the rest absorb', () {
      expect(catalogue.isDiffusion('promist-1/4'), isTrue);
      expect(catalogue.isDiffusion('w81a'), isFalse);
      expect(catalogue.isDiffusion('made-up'), isFalse);
    });

    test('a filter the menu no longer offers keeps its name', () {
      expect(catalogue.name('w81a'), '81A');
      expect(catalogue.name('w85c'), '85C');
      expect(catalogue.name('unknown'), 'unknown');
    });

    test('only the first of two diffusion filters acts', () {
      expect(catalogue.note(['w81a', 'promist-1/4']), isNull);
      expect(catalogue.note(['promist-1/4', 'fog-1']), 'Only the first diffusion filter acts.');
    });

    test('filters swap, come off and move', () {
      final stack = ['w81a', 'promist-1/4', 'w81a'];
      expect(replaceFilter(stack, 1, 'fog-1'), ['w81a', 'fog-1', 'w81a']);
      expect(replaceFilter(stack, 0, 'none'), ['promist-1/4', 'w81a']);
      expect(moveFilter(stack, 1, -1), ['promist-1/4', 'w81a', 'w81a']);
      expect(moveFilter(stack, 2, 1), stack);
      expect(stack, ['w81a', 'promist-1/4', 'w81a']);
    });
  });

  test('a lens with a profile or moved sliders can be reset', () {
    expect(hasLensAdjustments(defaultLens), isFalse);
    expect(hasLensAdjustments({...defaultLens, 'enabled': true}), isFalse);
    expect(hasLensAdjustments({...defaultLens, 'vignetting': .2}), isTrue);
    expect(hasLensAdjustments({...defaultLens, 'profileID': 'x'}), isTrue);
    expect(hasLensAdjustments({...defaultLens, 'amount': .5}), isTrue);
  });

  group('receiver bands', () {
    const paper = {'red': 700, 'green': 545, 'blue': 470};

    test('unset bands are the paper’s', () {
      expect(editBands({'screenGreenBand': 530}, paper), {'red': 700, 'green': 530, 'blue': 470});
    });

    test('bands set and cleared on a profile', () {
      final profile = {'push': 1, 'screenRedBand': 690};
      expect(withBands(profile, {'red': 680, 'green': 540, 'blue': 460}), {
        'push': 1,
        'screenRedBand': 680,
        'screenGreenBand': 540,
        'screenBlueBand': 460,
      });
      expect(withBands(profile, null), {'push': 1});
    });

    test('sets match on all three peaks', () {
      expect(sameBands(paper, {'name': 'Paper', ...paper}), isTrue);
      expect(sameBands(paper, {...paper, 'blue': 471}), isFalse);
      expect(sameBands(null, paper), isFalse);
    });
  });

  test('a frame request names the viewing light’s temperature', () {
    final edit = {
      'stock': 'gold200',
      'printFrame': 'mount',
      'format': null,
      'medium': 'screen',
      'profile': {'printLight': 'tungsten'},
    };
    final lights = [
      {'id': 'reference'},
      {'id': 'tungsten', 'value': 2856},
    ];
    expect(frameRequest(edit, lights, width: 300, height: 200), {
      'kind': 'print-frame',
      'stock': 'gold200',
      'frame': 'mount',
      'format': null,
      'medium': 'screen',
      'frameNumber': 1,
      'edgePrinting': true,
      'framing': [0, 0],
      'viewingKelvin': 2856,
      'width': 300,
      'height': 200,
    });
    expect(framesPicture(edit), isTrue);
    // A film border's frame number and edge printing travel with it.
    final film = {...edit, 'printFrame': 'film', 'printFrameNumber': 23, 'printFrameEdgePrinting': false};
    final request = frameRequest(film, lights);
    expect(request['frameNumber'], 23);
    expect(request['edgePrinting'], isFalse);
    expect(request['framing'], [0, 0]);
    expect(frameRequest({...film, 'printFrameFraming': [0.5, -1]}, lights)['framing'], [0.5, -1]);
  });

  test('a drag moves a film border over the photograph with the pointer, as far as its edges', () {
    // A 400 × 300 photograph cropped to 400 × 267 and shown in a frame 500 wide on 250 points.
    final plan = {
      'crop': {'x': 0, 'y': 17, 'width': 400, 'height': 267},
      'cropFraction': {'x': 0, 'y': 17 / 300, 'width': 1, 'height': 267 / 300},
      'placement': {
        'size': {'width': 500, 'height': 400},
      },
    };
    // Down 8 points is 16 photograph pixels: the aperture moves up by 16 of the 33 spare.
    final down = framingAfterDrag([0, 0], const Offset(30, 8), plan, 250);
    expect(down[0], 0); // nothing spare across
    expect(down[1], closeTo(-2 * 16 / 33, 1e-9));
    expect(framingAfterDrag([0, 0], const Offset(0, -100), plan, 250)[1], 1);
    expect(framesPicture({'printFrame': 'none'}), isFalse);
  });
}
