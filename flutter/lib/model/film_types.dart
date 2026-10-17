// The film library's film types, as the iPhone's film strip shelves them (FilmCategory in the
// consumer app's EditorFilmPicker.swift). Each film is placed from its own profile, which the
// engine's catalogue reports, so custom films sort themselves.
import 'catalogue.dart';

enum FilmType {
  all('All'),
  colorNegative('Color Negative'),
  slide('Slide'),
  blackAndWhite('B&W'),
  motionPicture('Motion Picture'),
  tungsten('Tungsten'),
  instant('Instant');

  const FilmType(this.title);
  final String title;

  /// Whether `stock` is a film of this type. Normal (null) is no film, so it is only in All.
  bool holds(Json? stock) {
    if (this == all) return true;
    if (stock == null) return false;
    final monochrome = stock['monochrome'] == true;
    final reversal = stock['reversal'] == true;
    final reflectionPrint = stock['reflectionPrint'] == true;
    final motionPicture = stock['motionPicture'] == true;
    return switch (this) {
      FilmType.all => true,
      FilmType.colorNegative => !monochrome && !reversal && !motionPicture,
      FilmType.slide => reversal && !monochrome && !reflectionPrint,
      FilmType.blackAndWhite => monochrome,
      FilmType.motionPicture => motionPicture,
      // Balanced for incandescent light rather than daylight: the 3200 K films.
      FilmType.tungsten => (stock['referenceKelvin'] as num? ?? 5500) < 4000,
      FilmType.instant => reflectionPrint,
    };
  }

  /// All, then each type some film is, in this order. An engine that does not report film types
  /// offers only All.
  static List<FilmType> offered(List<Json> stocks) => [
        for (final type in values)
          if (type == all || (stocks.any(type.holds) && stocks.first.containsKey('reversal'))) type,
      ];
}
