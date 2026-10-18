import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/crop_geometry.dart';
import 'package:fotufilm_flutter/model/edit.dart';
import 'package:fotufilm_flutter/model/editor.dart';

void expectPoints(List<Offset> actual, List<Offset> expected) {
  expect(actual.length, expected.length);
  for (var i = 0; i < actual.length; i++) {
    expect(actual[i].dx, closeTo(expected[i].dx, 1e-9), reason: 'point $i x');
    expect(actual[i].dy, closeTo(expected[i].dy, 1e-9), reason: 'point $i y');
  }
}

void main() {
  final full = cropPoints(fullCrop());

  group('crop geometry', () {
    test('the edit keeps a whole crop in whole numbers', () {
      expect(cropJson(full), fullCrop());
      expect(cropJson(rectangleCrop(.25, 0, 1, .5)), [
        [.25, 0],
        [1, 0],
        [1, .5],
        [.25, .5],
      ]);
    });

    test('a valid crop is a convex quadrilateral inside the frame', () {
      expect(validCrop(full), isTrue);
      expect(validCrop([full[0], full[2], full[1], full[3]]), isFalse);
      expect(validCrop(rectangleCrop(-.1, 0, 1, 1)), isFalse);
    });

    test('a ratio is the largest centred crop, turned to the frame', () {
      expect(orientedRatio('3:2', 4000, 6000), '2:3');
      expect(orientedRatio('3:2', 6000, 4000), '3:2');
      expect(orientedRatio('4:5', 6000, 4000), '5:4');
      expect(orientedRatio('1:1', 4000, 6000), '1:1');
      expectPoints(cropForRatio('1:1', 6000, 4000), rectangleCrop(1 / 6, 0, 5 / 6, 1));
      expectPoints(cropForRatio('original', 6000, 4000), full);
      final crop = cropForRatio('16:9', 4000, 4000);
      final size = outputSize(crop, const Size(4000, 4000));
      expect(size.width / size.height, closeTo(16 / 9, 1e-9));
    });

    test('rotating and flipping a four-corner crop carries its corners', () {
      final quad = [const Offset(.1, .2), const Offset(.9, .1), const Offset(.8, .9), const Offset(.2, .8)];
      // Four quarter turns come back to the same crop.
      var turned = quad;
      for (var i = 0; i < 4; i++) {
        turned = rotatedCrop(turned);
        expect(validCrop(turned), isTrue);
      }
      expectPoints(turned, quad);
      expectPoints(flippedCrop(flippedCrop(quad)), quad);
      expect(validCrop(flippedCrop(quad)), isTrue);
    });

    test('moving stops at the frame', () {
      final crop = rectangleCrop(.2, .2, .6, .6);
      expectPoints(moveCrop(crop, .1, -.1), rectangleCrop(.3, .1, .7, .5));
      expectPoints(moveCrop(crop, 1, 1), rectangleCrop(.6, .6, 1, 1));
    });

    test('a corner resizes against the opposite one, held to its ratio when locked', () {
      final crop = rectangleCrop(.2, .2, .6, .4);
      expectPoints(
        resizeCrop(crop, CropGrip.bottomRight, const Offset(.8, .9), shape: 'rectangle', locked: false),
        rectangleCrop(.2, .2, .8, .9),
      );
      final locked = resizeCrop(crop, CropGrip.bottomRight, const Offset(.8, .3),
          shape: 'rectangle', locked: true);
      final size = outputSize(locked, const Size(1, 1));
      expect(size.width / size.height, closeTo(2, 1e-9));
      expect(locked[0], const Offset(.2, .2));
      // The top left corner cannot pass the frame's edge.
      expectPoints(
        resizeCrop(crop, CropGrip.topLeft, const Offset(-.5, -.5), shape: 'rectangle', locked: false),
        rectangleCrop(0, 0, .6, .4),
      );
    });

    test('an edge resizes one side, and locked keeps the ratio about the centre', () {
      final crop = rectangleCrop(.2, .2, .6, .4);
      expectPoints(
        resizeCrop(crop, CropGrip.left, const Offset(.1, .9), shape: 'rectangle', locked: false),
        rectangleCrop(.1, .2, .6, .4),
      );
      final locked = resizeCrop(crop, CropGrip.right, const Offset(.8, .3),
          shape: 'rectangle', locked: true);
      expectPoints(locked, rectangleCrop(.2, .15, .8, .45));
      // An edge cannot pass the minimum from the opposite one.
      expectPoints(
        resizeCrop(crop, CropGrip.top, const Offset(.5, .9), shape: 'rectangle', locked: false,
            minimum: const Size(.05, .05)),
        rectangleCrop(.2, .35, .6, .4),
      );
    });

    test('a four-corner crop moves only the corner held, and never folds', () {
      final moved = resizeCrop(full, CropGrip.topRight, const Offset(.8, .1),
          shape: 'corners', locked: false);
      expectPoints(moved, [Offset.zero, const Offset(.8, .1), const Offset(1, 1), const Offset(0, 1)]);
      expect(resizeCrop(full, CropGrip.topRight, const Offset(0, 1), shape: 'corners', locked: false),
          same(full));
      expect(resizeCrop(full, CropGrip.top, const Offset(.5, .5), shape: 'corners', locked: false),
          same(full));
    });

    test('the delivered size follows the turn, the crop and the snap to whole pixels', () {
      final edit = <String, dynamic>{'rotation': 1, 'crop': fullCrop()};
      expect(deliveredSize(6000, 4000, edit), const Size(4000, 6000));
      edit['crop'] = cropJson(rectangleCrop(.1, .1, .6, .35));
      // 4000 x 6000 oriented: 0.5 x 4000 by 0.25 x 6000.
      expect(deliveredSize(6000, 4000, edit), const Size(2000, 1500));
      expect(deliveredSize(6000, 4000, edit, uncropped: true), const Size(4000, 6000));
      // A rectangle that cuts through pixels grows to whole ones.
      edit
        ..['rotation'] = 0
        ..['crop'] = cropJson(rectangleCrop(.09999, 0, .5, 1));
      expect(deliveredSize(10, 10, edit), const Size(5, 10));
      // Straightened, it is sampled as drawn.
      edit['straighten'] = 3;
      expect(deliveredSize(10, 10, edit), const Size(4, 10));
    });
  });

  group('crop tool', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late EditorModel editor;

    setUp(() async {
      editor = EditorModel(await Catalogue.load());
      editor.documents.add(PhotoDocument(
        path: '/photo.png',
        handle: 1,
        width: 6000,
        height: 4000,
        history: History(defaultEdit(editor.catalogue)),
      ));
      editor.activeIndex = 0;
    });

    test('open, the shown picture is the whole frame without the crop', () {
      editor.crop.setRatio('1:1');
      expect(editor.renderOptions(editor.active!), isEmpty);
      expect(editor.photoSize, const Size(4000, 4000));
      editor.toggleTool(Panel.crop);
      expect(editor.crop.showing, isTrue);
      final options = editor.renderOptions(editor.active!);
      expect(options['cropMode'], isTrue);
      expect((options['edit'] as Json)['crop'], fullCrop());
      expect((options['edit'] as Json)['ratio'], 'free');
      expect(editor.photoSize, const Size(6000, 4000));
      // The tool shows only while the inspector does.
      editor.toggleInspector();
      expect(editor.crop.showing, isFalse);
    });

    test('a ratio on a portrait frame turns, and the crop size reports it', () {
      editor.crop.rotateLeft();
      expect(editor.crop.frame, const Size(4000, 6000));
      editor.crop.setRatio('3:2');
      expect(editor.edit['ratio'], '3:2');
      expect(editor.crop.cropSize, const Size(4000, 6000));
      editor.crop.setRatio('16:9');
      expect(editor.crop.cropSize, const Size(3375, 6000));
    });

    test('rotating starts a rectangle over and flipping keeps it', () {
      editor.crop.setRatio('1:1');
      editor.crop.flip();
      expect(editor.edit['flip'], isTrue);
      expect(editor.edit['ratio'], '1:1');
      editor.crop.rotateLeft();
      expect(editor.edit['rotation'], 1);
      expect(editor.edit['crop'], fullCrop());
      expect(editor.edit['ratio'], 'free');
    });

    test('each change is one step, and Reset returns the untouched edit', () {
      editor.crop.setCrop(rectangleCrop(.1, .1, .9, .9));
      for (final v in [1.0, 2.0, 3.5]) {
        editor.crop.setGeometry('straighten', v);
      }
      editor.endEdit();
      editor.crop.setGeometry('perspectiveV', 10);
      editor.endEdit();
      expect(editor.active!.history.past.length, 3);
      expect(editor.edit['straighten'], 3.5);
      editor.undo();
      expect(editor.edit['perspectiveV'], 0);
      editor.undo();
      expect(editor.edit['straighten'], 0);
      editor.redo();
      editor.redo();
      editor.crop.reset();
      expect(editor.edited, isFalse);
    });

    test('Done leaves for the Film panel, and zoom waits', () {
      editor.setPanel(Panel.develop);
      editor.setZoom(2);
      expect(editor.zoomed, isTrue);
      editor.crop.toggle();
      expect(editor.panel, Panel.crop);
      expect(editor.zoomed, isFalse);
      editor.setZoom(2);
      expect(editor.zoomed, isFalse);
      editor.crop.done();
      expect(editor.panel, Panel.film);
      expect(editor.crop.showing, isFalse);
    });
  });
}
