import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/app/commands.dart';
import 'package:fotufilm_flutter/app/editor_shortcuts.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/edit.dart';
import 'package:fotufilm_flutter/model/editor.dart';
import 'package:fotufilm_flutter/ui/kit/popover.dart' show openModals;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EditorModel editor;
  late EditorCommands commands;
  var exported = 0;

  PhotoDocument photo(String path) => PhotoDocument(
      path: path,
      handle: 1,
      width: 600,
      height: 400,
      history: History(defaultEdit(editor.catalogue)));

  setUp(() async {
    editor = EditorModel(await Catalogue.load());
    editor.stocks = [
      {'id': 'gold200', 'name': 'Kodak Gold 200'},
    ];
    editor.documents.add(photo('/a.png'));
    editor.activeIndex = 0;
    exported = 0;
    void none() {}
    commands = EditorCommands(
      editor,
      CommandActions(
        open: none,
        export: () => exported++,
        copySettings: none,
        savePreset: none,
        managePresets: none,
        importLooks: none,
      ),
    );
  });

  group('the menu bar', () {
    test('is main_menu.mm, in its order', () {
      final titles = [for (final m in commands.menus) m.title];
      expect(titles, ['Fotufilm', 'File', 'Edit', 'Film', 'View', 'Window', 'Help']);
      final file = commands.menus[1].items;
      expect([for (final n in file) n is CommandNode ? n.id : n is NativeNode ? n.role : '-'], [
        'open', 'importNegative', 'importTrichromatic', 'openRecent', 'useSamplePhoto', '-', //
        'importFilmPack', '-', 'export', '-', 'closePhoto', 'closeWindow',
      ]);
      final view = commandNodes(commands.menus[4].items).toList();
      expect([for (final n in view.where((n) => n.id.startsWith('panel:'))) n.key!.label(mac: true)],
          ['⌘1', '⌘2', '⌘3', '⌘4', '⌘5', '⌘6']);
    });

    test('runs every command it lists', () {
      for (final node in commandNodes(commands.menus)) {
        expect(commands.handles(node.id), isTrue, reason: node.id);
      }
      for (final id in ['film:none', 'film:gold200', 'history:0', 'preset:x', 'grainModel:film']) {
        expect(commands.handles(id), isTrue, reason: id);
      }
    });

    test('writes key equivalents as the platform does', () {
      const negative = KeyEquivalent('n', alt: true);
      expect(negative.label(mac: true), '⌥⌘N');
      expect(negative.label(mac: false), 'Ctrl+Alt+N');
      expect(const KeyEquivalent('h', control: true).label(mac: true), '⌃⌘H');
      expect(const KeyEquivalent('h', control: true).offeredWithCtrl, isFalse);
      expect(shortcutLabel('⇧⌘Z', mac: false), 'Ctrl+Shift+Z');
      expect(shortcutLabel('⌥⌘C', mac: true), '⌥⌘C');
    });
  });

  group('menuState', () {
    test('Undo names its step, and the film list ticks the one loaded', () {
      var state = commands.state();
      expect(state.isEnabled('undo'), isFalse);
      expect(state.title('undo', 'Undo'), 'Undo');
      expect(state.isChecked('film:none'), isTrue);
      expect(state.list('films').map((f) => f.$2), ['Normal', 'Kodak Gold 200']);
      editor.setParam('ev', 1);
      editor.endEdit();
      state = commands.state();
      expect(state.isEnabled('undo'), isTrue);
      expect(state.title('undo', 'Undo'), 'Undo Light');
      expect(state.history, ['Opened', 'Light']);
      expect(state.isChecked('history:1'), isTrue);
      expect(state.isEnabled('export'), isTrue);
      expect(state.isEnabled('newGrainPattern'), isFalse);
    });

    test('a dialog or the library covers the photo', () {
      editor.setParam('ev', 1);
      editor.endEdit();
      openModals.value = 1;
      var state = commands.state();
      expect(state.isEnabled('undo'), isFalse);
      expect(state.isEnabled('export'), isFalse);
      expect(state.isEnabled('settings'), isTrue);
      openModals.value = 0;
      editor.library.setOpen(true);
      state = commands.state();
      expect(state.isEnabled('closePhoto'), isFalse);
      expect(state.isEnabled('inspector'), isFalse);
      editor.library.setOpen(false);
    });

    test('the zoom items follow the view, and the panels tick the one shown', () {
      editor.updateViewer(const Size(600, 400), 1);
      var state = commands.state();
      expect(state.isEnabled('zoomIn'), isTrue);
      expect(state.isEnabled('zoomOut'), isFalse);
      expect(state.isEnabled('zoomToFit'), isFalse);
      expect(state.isChecked('panel:film'), isTrue);
      commands.run('zoomIn');
      state = commands.state();
      expect(state.isEnabled('zoomOut'), isTrue);
      commands.run('panel:crop');
      state = commands.state();
      expect(editor.panel, Panel.crop);
      expect(state.isChecked('panel:crop'), isTrue);
      // The crop tool shows the whole frame, fitted.
      expect(state.isEnabled('zoomIn'), isFalse);
    });

    test('Paste Settings names how many photos it pastes onto', () {
      editor.documents.add(photo('/b.png'));
      expect(commands.state().title('pasteSettings', ''), 'Paste Settings');
      editor.selection.selectAll();
      expect(commands.state().title('pasteSettings', ''), 'Paste Settings to 2 Photos');
    });

    test('a command that does not apply does not run', () {
      expect(commands.run('undo'), isFalse);
      expect(commands.run('film:gold200'), isTrue);
      expect(editor.edit['stock'], 'gold200');
      expect(commands.run('nothing'), isFalse);
    });
  });

  group('the keyboard', () {
    late EditorShortcuts shortcuts;
    final field = TextEditingController();
    final fieldFocus = FocusNode();

    Future<void> pump(WidgetTester tester) async {
      shortcuts = EditorShortcuts(commands);
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) => shortcuts.handle(event),
          child: EditableText(
            controller: field,
            focusNode: fieldFocus,
            style: const TextStyle(),
            cursorColor: const Color(0xFF000000),
            backgroundCursorColor: const Color(0xFF000000),
          ),
        ),
      ));
      await tester.pump();
    }

    final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

    testWidgets('single keys, Esc and Space work while no field has the keys', variant: mac,
        (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      expect(editor.histogramOpen, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(editor.panel, Panel.crop);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(editor.panel, Panel.film);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      expect(editor.comparing, isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(editor.comparing, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      expect(editor.library.open, isTrue);
      // The library keeps the rest of the editor's keys to itself.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      expect(editor.histogramOpen, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      expect(editor.library.open, isFalse);
    });

    testWidgets('a text field keeps its keys; the menus keep theirs', variant: mac,
        (tester) async {
      await pump(tester);
      fieldFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      expect(editor.histogramOpen, isFalse);
      // ⌘E is the File menu's, wherever the keys are.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(exported, 1);
    });

    testWidgets('⌘A chooses every open photo, ⌥⌘N shows nothing it cannot', variant: mac,
        (tester) async {
      editor.documents.add(photo('/b.png'));
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(editor.selection.chosen.length, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(editor.selection.chosen.length, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(editor.negatives.showNegative, isFalse);
      // Esc's fit settles before the develop it asks for.
      await tester.pump(const Duration(milliseconds: 200));
    });
  });

  test('the shortcuts dialog lists its rows', () {
    final rows = shortcutRows(editor, mac: false);
    expect(rows.first, ('Open images', 'Ctrl+O'));
    expect(rows[1], ('Export', 'Ctrl+E'));
    expect(rows[2], ('Undo', 'Ctrl+Z'));
    expect(rows[4].$2, 'Ctrl+Shift+A');
    expect(rows.length, 20);
    expect(rows.last, ('Reset adjustment', 'Double-click slider'));
  });
}
