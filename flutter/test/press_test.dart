import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/ui/kit/buttons.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      Directionality(textDirection: TextDirection.ltr, child: Center(child: child)));

  testWidgets('a menu trigger acts as the press starts', (tester) async {
    var pressed = 0;
    await pump(
      tester,
      // A double-click around it, as the title bar has, adds no wait.
      GestureDetector(
        onDoubleTap: () {},
        child: QuietButton(label: 'More', opensMenu: true, onPressed: () => pressed++),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.byType(QuietButton)),
        kind: PointerDeviceKind.mouse);
    expect(pressed, 1);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(pressed, 1);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a button over the title bar surface acts at once; one inside it waits',
      (tester) async {
    var pressed = 0;
    Widget button() => QuietButton(label: 'Undo', onPressed: () => pressed++);

    // The toolbar's arrangement: the drag and zoom surface behind the controls.
    await pump(
      tester,
      SizedBox(
        width: 200,
        height: 40,
        child: Stack(children: [
          Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onDoubleTap: () {})),
          Center(child: button()),
        ]),
      ),
    );
    await tester.tap(find.byType(QuietButton), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(pressed, 1);

    // Around them, a double-click holds the press until no second click can come.
    await pump(tester, GestureDetector(onDoubleTap: () {}, child: button()));
    await tester.tap(find.byType(QuietButton), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(pressed, 1);
    await tester.pump(kDoubleTapTimeout);
    expect(pressed, 2);
    await tester.pump(const Duration(seconds: 1));
  });
}
