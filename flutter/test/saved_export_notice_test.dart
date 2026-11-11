import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/editor.dart';
import 'package:fotufilm_flutter/model/export.dart' show SavedExport;
import 'package:fotufilm_flutter/ui/workspace/saved_export_notice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a long filename is cut short, so Dismiss stays in reach on a phone', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final editor = EditorModel(await tester.runAsync(Catalogue.load) as Catalogue);
    editor.exporter.saved = const SavedExport(
        filename: 'harbour-at-dusk-aerochrome1443-screen-acros100-ektacolor-edge.png',
        path: '/out/harbour.png');

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: ListenableBuilder(
          listenable: editor,
          builder: (_, _) => Stack(children: [SavedExportNotice(editor: editor)])),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'the card fits the window');

    final dismiss = tester.getRect(find.text('Dismiss'));
    expect(dismiss.right, lessThanOrEqualTo(390));
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(editor.exporter.saved, isNull);
    expect(find.text('Dismiss'), findsNothing);
  });
}
