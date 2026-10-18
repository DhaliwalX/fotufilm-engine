import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/film_types.dart';

Map<String, dynamic> film({
  bool monochrome = false,
  bool reversal = false,
  bool reflectionPrint = false,
  bool motionPicture = false,
  double kelvin = 5500,
}) =>
    {
      'monochrome': monochrome,
      'reversal': reversal,
      'reflectionPrint': reflectionPrint,
      'motionPicture': motionPicture,
      'referenceKelvin': kelvin,
    };

void main() {
  test('each film is shelved by its profile, as on the iPhone', () {
    final portra = film();
    final ektachrome = film(reversal: true);
    final hp5 = film(monochrome: true);
    final vision3 = film(motionPicture: true, kelvin: 3200);
    final instax = film(reversal: true, reflectionPrint: true);
    expect(FilmType.colorNegative.holds(portra), isTrue);
    expect(FilmType.colorNegative.holds(vision3), isFalse);
    expect(FilmType.slide.holds(ektachrome), isTrue);
    expect(FilmType.slide.holds(instax), isFalse);
    expect(FilmType.blackAndWhite.holds(hp5), isTrue);
    expect(FilmType.motionPicture.holds(vision3), isTrue);
    expect(FilmType.tungsten.holds(vision3), isTrue);
    expect(FilmType.tungsten.holds(portra), isFalse);
    expect(FilmType.instant.holds(instax), isTrue);
  });

  test('Normal is only in All', () {
    expect(FilmType.all.holds(null), isTrue);
    for (final type in FilmType.values.skip(1)) {
      expect(type.holds(null), isFalse);
    }
  });

  test('only types with films are offered, and only All without type fields', () {
    expect(FilmType.offered([film(), film(monochrome: true)]),
        [FilmType.all, FilmType.colorNegative, FilmType.blackAndWhite]);
    expect(FilmType.offered([
      {'id': 'old', 'name': 'Old'},
    ]), [FilmType.all]);
  });
}
