import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/editor.dart';
import 'package:fotufilm_flutter/ui/theme/metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Catalogue catalogue;
  setUpAll(() async => catalogue = await Catalogue.load());

  /// An editor in a phone's window, both docks closed.
  EditorModel phone() => EditorModel(catalogue)..layout.layOut(390);

  group('the compact rail', () {
    test('a narrowed window closes both docks, and no button reads as chosen', () {
      final editor = phone();
      expect(editor.layout.compact, isTrue);
      expect(editor.filmOpen || editor.inspectorOpen, isFalse);
      for (final p in editor.inspectorTabs) {
        expect(editor.layout.railShowing(p), isFalse);
      }
    });

    test('a button opens its dock, another switches it, and pressed again it closes', () {
      final editor = phone();
      final layout = editor.layout;
      layout.railPressed(Panel.light);
      expect((editor.inspectorOpen, editor.filmOpen, editor.panel), (true, false, Panel.light));
      expect(layout.railShowing(Panel.light), isTrue);

      layout.railPressed(Panel.develop);
      expect((editor.inspectorOpen, editor.panel), (true, Panel.develop));
      expect(layout.railShowing(Panel.light), isFalse);

      layout.railPressed(Panel.develop);
      expect(editor.inspectorOpen || editor.filmOpen, isFalse);
    });

    test('Film opens the film list in place of the inspector, and closes it', () {
      final editor = phone();
      final layout = editor.layout;
      layout.railPressed(Panel.print);
      layout.railPressed(Panel.film);
      expect((editor.filmOpen, editor.inspectorOpen), (true, false));
      expect(layout.railShowing(Panel.film), isTrue);
      expect(layout.railShowing(Panel.print), isFalse);

      layout.railPressed(Panel.film);
      expect(editor.filmOpen || editor.inspectorOpen, isFalse);
    });

    test('Film settings keep the Film button chosen, which then closes them', () {
      final editor = phone();
      final layout = editor.layout;
      layout.railPressed(Panel.film);
      layout.filmSettings();
      expect((editor.filmOpen, editor.inspectorOpen, editor.panel), (false, true, Panel.film));
      expect(layout.railShowing(Panel.film), isTrue);

      layout.railPressed(Panel.film);
      expect(editor.filmOpen || editor.inspectorOpen, isFalse);
    });
  });

  group('the compact dock', () {
    test('its grabber sets the height, within the room left for the picture', () {
      final layout = phone().layout;
      layout.dragDock(260, 400);
      expect(layout.dockHeight, 260);
      layout.dragDock(900, 400);
      expect(layout.dockHeight, 400);
    });

    test('pulled well down or flung down, it closes and comes back at its height', () {
      final editor = phone();
      final layout = editor.layout..railPressed(Panel.light);
      layout.dragDock(Metrics.compactDockMin * .5, 400);
      layout.releaseDock(0, before: 300);
      expect(editor.inspectorOpen, isFalse);
      expect(layout.dockHeight, 300);

      layout.railPressed(Panel.light);
      layout.releaseDock(1200, before: 300);
      expect(editor.inspectorOpen, isFalse);
    });

    test('let go at a height it can keep, it stays open there', () {
      final editor = phone();
      final layout = editor.layout..railPressed(Panel.light);
      layout.dragDock(250, 400);
      layout.releaseDock(0, before: 300);
      expect((editor.inspectorOpen, layout.dockHeight), (true, 250));
    });
  });
}
