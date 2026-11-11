// The driver's commands for the phone's gallery (driver.dart). An entry is named by its place in
// the gallery's order (0 the most recently edited) or by its id, a roll by its name:
//
//   {"gallery": true}                     logs what is kept, the rolls, and what is shown
//   {"galleryOpen": 0}                    opens an entry in the editor
//   {"galleryClose": true}                leaves the editor for the gallery
//   {"galleryKeep": true}                 keeps what was edited now, without the wait
//   {"galleryDelete": 0}                  deletes an entry
//   {"galleryTab": "negatives"}           shows the photos or the negatives
//   {"galleryRoll": ["Name", "2026-05-01"]}  makes a roll
//   {"galleryShowRoll": "Name"}           opens a roll (null closes it)
//   {"galleryFile": [0, "Name"]}          files a scan in a roll (null takes it out)
//   {"galleryDeleteRoll": ["Name", true]} deletes a roll, with its frames or without
import '../model/editor.dart';

Future<void> driveGallery(
    EditorModel editor, Map<String, dynamic> c, void Function(String) log) async {
  final gallery = editor.gallery;
  GalleryEntry? entry(Object? named) => switch (named) {
        final int index when index >= 0 && index < gallery.entries.length => gallery.entries[index],
        final String id => gallery.entries.where((e) => e.id == id).firstOrNull,
        _ => null,
      };
  GalleryRoll? roll(Object? name) => gallery.rolls.where((r) => r.name == name).firstOrNull;

  if (c.containsKey('galleryOpen')) {
    final opened = entry(c['galleryOpen']);
    if (opened != null) await gallery.open(opened);
    log('galleryOpen ${opened?.name} active ${editor.active?.name} error ${editor.error}');
  }
  if (c['galleryClose'] == true) await gallery.closeEditor();
  if (c['galleryKeep'] == true) await gallery.keep();
  if (c.containsKey('galleryDelete')) {
    final deleted = entry(c['galleryDelete']);
    if (deleted != null) await gallery.delete(deleted);
  }
  if (c['galleryTab'] case final String tab) gallery.tab = GalleryTab.values.byName(tab);
  if (c['galleryRoll'] case [final String name, final String date]) {
    gallery.createRoll(name, DateTime.parse(date));
  }
  if (c.containsKey('galleryShowRoll')) gallery.showRoll(roll(c['galleryShowRoll']));
  if (c['galleryFile'] case [final named, final name]) {
    final filed = entry(named);
    if (filed != null) await gallery.fileIn(filed, roll(name));
  }
  if (c['galleryDeleteRoll'] case [final String name, final bool frames]) {
    final deleted = roll(name);
    if (deleted != null) await gallery.deleteRoll(deleted, frames: frames);
  }
  if (c.keys.any((key) => key.startsWith('gallery'))) {
    log('gallery available ${gallery.available} shown ${gallery.shown} '
        'tab ${gallery.tabbed ? gallery.tab.name : null} roll ${gallery.rollOpen?.name} '
        'entries ${[
      for (final e in gallery.entries)
        '${e.name}${e.negative ? ' negative' : e.video ? ' video' : ''}'
            '${gallery.rollOf(e) == null ? '' : ' in ${gallery.rollOf(e)!.name}'}'
    ]} rolls ${[for (final r in gallery.rolls) '${r.name} ${gallery.framesOf(r).length}']}');
  }
}
