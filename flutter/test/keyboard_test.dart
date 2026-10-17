import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/ui/kit/kit.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await IconLibrary.load();
  });

  Future<void> show(WidgetTester tester, Widget child) => tester.pumpWidget(WidgetsApp(
        color: const Color(0xFF000000),
        localizationsDelegates: const [
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        builder: (_, _) => Overlay(initialEntries: [
          // The keys start where the workspace holds them.
          OverlayEntry(
              builder: (_) => FocusScope(
                  autofocus: true, child: Align(alignment: Alignment.topLeft, child: child))),
        ]),
      )).then((_) => tester.pump());

  testWidgets('Tab reaches a button and Return or Space works it', (tester) async {
    var pressed = 0;
    await show(
        tester,
        Row(mainAxisSize: MainAxisSize.min, children: [
          QuietButton(icon: 'close', tooltip: 'Close', onPressed: () => pressed++),
          const QuietButton(icon: 'help', tooltip: 'Disabled'),
        ]));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(pressed, 2);
  });

  testWidgets('a click puts no ring on a button; the keyboard does', (tester) async {
    await show(tester, QuietButton(icon: 'close', tooltip: 'Close', onPressed: () {}));
    Finder ring() => find.descendant(
        of: find.byType(KeyTarget), matching: find.byType(DecoratedBox));
    final before = ring().evaluate().length;
    await tester.tap(find.byType(QuietButton));
    await tester.pump();
    expect(ring().evaluate().length, before);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ring().evaluate().length, before + 1);
  });

  testWidgets('the arrow keys step a slider, Shift by ten', (tester) async {
    var value = 0.0, ends = 0;
    await show(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 200,
            child: TrackSlider(
              value: value,
              min: 0,
              max: 100,
              onChanged: (v) => setState(() => value = v),
              onEnd: () => ends++,
            ),
          ),
        ));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(value, 11);
    expect(ends, 2, reason: 'each key is one change');
  });

  testWidgets('Esc closes a popover and the keys go back to its button', (tester) async {
    AnchoredOverlay? shown;
    await show(
        tester,
        Builder(
          builder: (anchor) => QuietButton(
            icon: 'more',
            tooltip: 'More',
            onPressed: () => shown = showAnchored(anchor, (_, close) => const SizedBox(width: 100, height: 50)),
          ),
        ));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(shown!.isOpen, isTrue);
    expect(FocusManager.instance.primaryFocus, isNot(button));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(shown!.isOpen, isFalse);
    expect(FocusManager.instance.primaryFocus, button);
  });

  testWidgets('the arrow keys move through a menu and Return chooses', (tester) async {
    String? chosen;
    await show(
        tester,
        Builder(
          builder: (anchor) => QuietButton(
            icon: 'more',
            tooltip: 'More',
            onPressed: () => showMenu(anchor, [
              MenuItem(label: 'First', onSelected: () => chosen = 'First'),
              MenuItem(label: 'Second', onSelected: () => chosen = 'Second'),
            ]),
          ),
        ));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chosen, 'Second');
  });

  testWidgets('VoiceOver reads each control with its role and state', (tester) async {
    final semantics = tester.ensureSemantics();
    await show(
        tester,
        SizedBox(
          width: 300,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            QuietButton(icon: 'close', tooltip: 'Close', onPressed: () {}),
            SwitchRow(label: 'Magnified Detail', value: true, onChanged: (_) {}),
            SegmentedControl<int>(items: const [(0, 'Film'), (1, 'Print')], selected: 1, onChanged: (_) {}),
            AdjustmentRow(
              label: 'Exposure',
              value: 0.5,
              range: const SliderRange(min: -3, max: 3, step: 0.01, def: 0),
              onChanged: (_) {},
            ),
          ]),
        ));
    expect(tester.getSemantics(find.bySemanticsLabel('Close')),
        isSemantics(label: 'Close', isButton: true, isEnabled: true, hasTapAction: true));
    expect(tester.getSemantics(find.bySemanticsLabel('Magnified Detail')),
        isSemantics(hasToggledState: true, isToggled: true));
    expect(tester.getSemantics(find.bySemanticsLabel('Print')),
        isSemantics(isButton: true, hasSelectedState: true, isSelected: true));
    expect(tester.getSemantics(find.bySemanticsLabel('Exposure').last),
        isSemantics(isSlider: true, value: '0.5', hasIncreaseAction: true));
    semantics.dispose();
  });
}
