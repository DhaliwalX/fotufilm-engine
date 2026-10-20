import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/film_packs.dart';
import 'package:fotufilm_flutter/model/histogram.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/new_photo.dart';
import 'package:fotufilm_flutter/model/panel_layout.dart';
import 'package:fotufilm_flutter/model/plugins.dart';
import 'package:fotufilm_flutter/model/saved_edits.dart';
import 'package:fotufilm_flutter/model/settings.dart';
import 'package:fotufilm_flutter/model/updates.dart';

late Catalogue catalogue;
const _films = [
  {'id': 'gold200', 'filmMedium': 'ra4'},
  {'id': 'portra400', 'filmMedium': 'endura'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => catalogue = await Catalogue.load());

  group('a new photo', () {
    test('starts on the shown film and the default film model', () {
      final edit = newPhotoEdit(catalogue, AppSettings.memory(), 'gold200', _films);
      expect(edit['stock'], 'gold200');
      expect(edit['format'], isNull);
      expect(edit['halationModel'], 'legacy');
      expect(edit['profile'], isEmpty);
      // The print matches the film: Match Film, on the film's own medium.
      expect(edit['mediumFollowsFilm'], isTrue);
      expect(edit['medium'], 'ra4');
    });

    test('takes the starting film, format and film model', () {
      final settings = AppSettings.memory()
        ..set('startingFilm', 'portra400')
        ..set('startingFormat', '16mm')
        ..set('grainModel', 'film')
        ..set('halationModel', 'layered')
        ..set('estimatedHalation', true)
        ..set('couplerReach', 1.5)
        ..set('couplerRedGreen', 2)
        ..set('couplerGreenBlue', 1.5)
        ..set('couplerSelf', 1);
      final edit = newPhotoEdit(catalogue, settings, 'gold200', _films);
      expect(edit['stock'], 'portra400');
      expect(edit['medium'], 'endura');
      expect(edit['format'], '16mm');
      expect(edit['halationModel'], 'layered');
      // A pair left at Separation follows it; one set on its own starts there.
      expect(edit['profile'], {
        'grainModel': 'film',
        'estimatedHalation': true,
        'couplerReach': 1.5,
        'couplerRedGreen': 2,
      });
    });

    test('ignores a film the library lacks, and Normal starts without one', () {
      final settings = AppSettings.memory()..set('startingFilm', 'gone');
      expect(newPhotoEdit(catalogue, settings, 'gold200', _films.take(1))['stock'], 'gold200');
      settings.set('startingFilm', 'none');
      final normal = newPhotoEdit(catalogue, settings, 'gold200', _films);
      expect(normal['stock'], isNull);
      expect(normal['medium'], isNull);
    });

    test('Restore Film Model follows any change from the defaults', () {
      final settings = AppSettings.memory();
      expect(filmModelAdjusted(settings), isFalse);
      settings.set('couplerSelf', 1.2);
      expect(filmModelAdjusted(settings), isTrue);
    });
  });

  group('panel widths', () {
    test('a narrow window takes room from the inspector first, then the films', () {
      const asked = (film: 300.0, inspector: 400.0);
      expect(shownWidths(asked, 2000), (film: 300.0, inspector: 400.0));
      expect(shownWidths(asked, 1100), (film: 300.0, inspector: 380.0));
      // Each keeps its least width in a window too narrow for all three.
      expect(shownWidths(asked, 700), (film: 180.0, inspector: 280.0));
    });

    test('kept widths are bounded, and missing ones take the defaults', () {
      expect(keptWidths({'film': 1000, 'inspector': 10}), (film: 480.0, inspector: 280.0));
      expect(keptWidths(null).film, panelBounds(PanelSide.film).initial);
    });
  });

  group('histogram', () {
    test('counts every channel of the opaque pixels', () {
      final rgba = Uint8List.fromList([255, 0, 0, 255, 128, 128, 128, 255, 0, 0, 0, 0]);
      final data = HistogramData.statistics(rgba);
      expect(data.count, 2);
      expect(data.red[255], 1);
      expect(data.green[128], 1);
      // A grey is neutral: its colour differences and a/b sit in the middle.
      expect(data.channels[4][128], 1);
      expect(data.channels[7][128], 1);
      expect(data.channels[6].reduce((a, b) => a + b), 2);
    });

    test('smoothing conserves the counts', () {
      final values = List<num>.filled(256, 0)..[0] = 100..[128] = 50;
      final smooth = smoothHistogram(values);
      expect(smooth.reduce((a, b) => a + b), closeTo(150, 1e-9));
      expect(smooth[0], greaterThan(smooth[3]));
    });

    test('the count axis rounds up to a readable limit', () {
      expect(histogramCountAxis(420, log: true).max, 1000);
      expect(histogramCountAxis(420, log: true).ticks, [0, 1, 10, 100, 1000]);
      final linear = histogramCountAxis(420, log: false);
      expect(linear.max, 600);
      expect(linear.ticks, [0, 200, 400, 600]);
      expect(histogramTickLabel(1500), '1.5k');
      expect(histogramTickLabel(2000), '2k');
    });
  });

  group('plug-ins', () {
    final list = [
      {'id': 'resolve', 'name': 'DaVinci Resolve', 'state': 'notInstalled',
        'bundledVersion': '12', 'hostInstalled': true},
      {'id': 'fcp', 'name': 'Final Cut Pro', 'state': 'installed', 'bundledVersion': '12',
        'installedVersion': '12', 'hostInstalled': true},
    ];

    test('the launch offer names what is missing, unless this build was declined', () {
      final offer = PluginOffer.of(list, null)!;
      expect(offer.ids, ['resolve']);
      expect(offer.updating, isFalse);
      expect(PluginOffer.of(list, '12'), isNull);
    });

    test('a plug-in\'s state reads as the Mac app words it', () {
      expect(pluginStatusText(list[1]), 'Installed (build 12).');
      expect(installLabel(list[1]), 'Reinstall');
      expect(pluginStatusText(null), 'Checking…');
      expect(joinedNames(['A', 'B', 'C']), 'A, B and C');
    });
  });

  group('updates', () {
    test('a manual check always answers; an automatic one only with news', () {
      final current = {'state': 'current', 'current': '1.10 (build 12)'};
      expect(checkOutcome(current, manual: false), isNull);
      expect((checkOutcome(current, manual: true) as UpdateNotice).title, "You're up to date");
      final available = {
        'state': 'available',
        'version': '1.11',
        'release': '1.11 (build 14)',
        'current': '1.10 (build 12)',
      };
      expect(checkOutcome(available, manual: false, skipped: '1.11 (build 14)'), isNull);
      final offer = checkOutcome(available, manual: false) as UpdateAvailable;
      expect(offer.version, '1.11');
      expect(offer.allowSkip, isTrue);
    });

    test('a pre-release of the running version is named by its build', () {
      final offer = checkOutcome({
        'state': 'available',
        'version': '1.10',
        'release': '1.10 (build 13)',
        'current': '1.10 (build 12)',
      }, manual: true) as UpdateAvailable;
      expect(offer.version, '1.10 (build 13)');
    });

    test('byte counts read as the Mac formats them', () {
      expect(formatBytes(0), 'Zero KB');
      expect(formatBytes(950), '950 bytes');
      expect(formatBytes(12300000), '12.3 MB');
    });
  });

  test('film pack results arriving together make one notice', () {
    final notice = PackNotice.of(const [
      PackNotice('Pack added', 'One v1 — 3 films', added: true),
      PackNotice('Pack not added', 'Two: damaged'),
    ]);
    expect(notice.title, 'Film packs');
    expect(notice.added, isTrue);
    expect(notice.message, 'Pack added: One v1 — 3 films\n\nPack not added: Two: damaged');
    expect(isFilmPack('Test.FotufilmPack'), isTrue);
  });
}
