import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/ui/kit/popover.dart';

void main() {
  // An 800 × 600 window with the anchor at `top`.
  Future<BuildContext> window(WidgetTester tester, double top) async {
    late BuildContext anchor;
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Overlay(initialEntries: [
        OverlayEntry(
          builder: (_) => Stack(children: [
            Positioned(
              left: 600,
              top: top,
              width: 180,
              height: 24,
              child: Builder(builder: (context) {
                anchor = context;
                return const SizedBox.expand();
              }),
            ),
          ]),
        ),
      ]),
    ));
    return anchor;
  }

  AnchoredOverlay open(WidgetTester tester, BuildContext anchor, double height,
          {bool above = false}) =>
      showAnchored(anchor, (_, _) => SizedBox(key: const Key('popover'), height: height),
          matchWidth: true, above: above);

  Rect popover(WidgetTester tester) => tester.getRect(find.byKey(const Key('popover')));

  testWidgets('opens under its anchor where there is room', (tester) async {
    open(tester, await window(tester, 100), 200);
    await tester.pumpAndSettle();
    expect(popover(tester), const Rect.fromLTWH(600, 128, 180, 200));
  });

  testWidgets('a picker near the bottom of the window opens over it, inside the window',
      (tester) async {
    open(tester, await window(tester, 540), 200);
    await tester.pumpAndSettle();
    expect(popover(tester), const Rect.fromLTWH(600, 336, 180, 200));
  });

  testWidgets('a popover taller than either side is held to the larger, to scroll', (tester) async {
    open(tester, await window(tester, 400), 1000);
    await tester.pumpAndSettle();
    final rect = popover(tester);
    expect(rect.top, 8);
    expect(rect.bottom, 396);
  });

  testWidgets('one asked to open above opens under where there is no room above', (tester) async {
    open(tester, await window(tester, 40), 200, above: true);
    await tester.pumpAndSettle();
    expect(popover(tester).top, 68);
  });

  testWidgets('a popover fades in, and out before it leaves', (tester) async {
    final overlay = open(tester, await window(tester, 100), 200);
    await tester.pump();
    double opacity() => tester.widget<FadeTransition>(find.ancestor(
        of: find.byKey(const Key('popover')), matching: find.byType(FadeTransition))).opacity.value;
    expect(opacity(), lessThan(1));
    await tester.pumpAndSettle();
    expect(opacity(), 1);

    overlay.close();
    expect(overlay.isOpen, isFalse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('popover')), findsOneWidget);
    expect(opacity(), lessThan(1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('popover')), findsNothing);
  });
}
