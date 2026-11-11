// The gallery: the photographs kept in Fotufilm on a phone, where the app opens. A photograph
// joins once it is edited (one opened and closed untouched leaves nothing behind); a scanned
// negative joins as it opens. Each is a copy of its file in the app's own folder with a small
// record beside it and a picture of it developed, which is what its tile shows. Negatives can be
// filed in rolls, each a folder of frames. The editor shows one photograph at a time, with no
// strip of the others: the gallery is where another is chosen.
//
// The edits are not the gallery's: every photograph keeps its last edit under its identity
// (kept_edits.dart), and one opened from here starts where it was left.
//
//   <gallery>/entries/<id>.json   the record: file, dates, film, kind, roll
//   <gallery>/entries/<id>.png    the tile's picture
//   <gallery>/photos/<id>/<name>  the photograph, under its own name
//   <gallery>/rolls/<roll>/<name> a frame filed in a roll
//   <gallery>/rolls.json          the rolls: name and date
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../engine/engine.dart';
import 'edit.dart';
import 'editor.dart';
import 'gallery_files.dart';
import 'negative_document.dart';
import 'renderer.dart' show decodePng;
import 'saved_edits.dart';

/// One photograph, movie or scanned negative in the gallery.
class GalleryEntry {
  GalleryEntry({
    required this.id,
    required this.file,
    required this.created,
    required this.modified,
    this.stock,
    this.video = false,
    this.negative = false,
    this.identity,
    this.roll,
  });

  /// The entry a record describes, or null for one that is not an entry's.
  static GalleryEntry? fromJson(Json json) {
    final id = json['id'], file = json['file'];
    if (id is! String || file is! String) return null;
    final created = (json['created'] as num?)?.toInt() ?? 0;
    return GalleryEntry(
      id: id,
      file: file,
      created: created,
      modified: (json['modified'] as num?)?.toInt() ?? created,
      stock: json['stock'] as String?,
      video: json['video'] == true,
      negative: json['negative'] == true,
      identity: json['identity'] as String?,
      roll: json['roll'] as String?,
    );
  }

  final String id;

  /// Where its file is, from the gallery's folder.
  String file;

  /// When it joined and when its edit last changed, in milliseconds.
  final int created;
  int modified;

  /// The film it was last developed on.
  String? stock;
  final bool video, negative;

  /// The engine's identity for the file, which its kept edit is under.
  final String? identity;

  /// The roll a frame is filed in.
  String? roll;

  String get name => file.substring(file.lastIndexOf('/') + 1);

  Json toJson() => {
        'id': id,
        'file': file,
        'created': created,
        'modified': modified,
        'stock': stock,
        'video': video,
        'negative': negative,
        'identity': identity,
        'roll': roll,
      };
}

/// A roll of scanned negatives: a name and the day it was shot.
class GalleryRoll {
  GalleryRoll({required this.id, required this.name, required this.date, required this.created});

  static GalleryRoll? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    final created = (json['created'] as num?)?.toInt() ?? 0;
    return GalleryRoll(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      date: (json['date'] as num?)?.toInt() ?? created,
      created: created,
    );
  }

  final String id;
  String name;

  /// The day it was shot, and when it was made, in milliseconds.
  int date;
  final int created;

  DateTime get day => DateTime.fromMillisecondsSinceEpoch(date);

  Json toJson() => {'id': id, 'name': name, 'date': date, 'created': created};
}

/// What the gallery lists when it holds both photographs and negatives.
enum GalleryTab { photos, negatives }

class Gallery extends ChangeNotifier {
  Gallery(this.editor, {String? folder}) : root = folder ?? galleryFolder() {
    final root = this.root;
    if (root == null) return;
    if (readRecord('$root/rolls.json') case final List list) {
      rolls.addAll(list.map(GalleryRoll.fromJson).nonNulls);
    }
    for (final record in readRecords('$root/entries')) {
      final entry = GalleryEntry.fromJson(record);
      if (entry == null) continue;
      // A frame whose roll has gone lies loose.
      if (_roll(entry.roll) == null) entry.roll = null;
      entries.add(entry);
    }
    _sort();
    _openId = editor.settings.get<String>(_openKey);
    _shown = _openId == null;
    editor.editListeners.add(_edited);
    editor.addListener(_follow);
    // What waits is kept before the app goes to the background.
    // The listener stays registered with the binding for the app's life.
    AppLifecycleListener(onInactive: keep);
  }

  final EditorModel editor;

  /// The gallery's folder, or null where there is none (a desktop, a browser).
  final String? root;

  /// Whether the app is laid out for a phone (the workspace says): only a phone has the gallery.
  bool get phone => _phone;
  bool _phone = false;
  set phone(bool value) {
    if (value == _phone) return;
    _phone = value;
    if (value && _restoring) scheduleMicrotask(restore);
  }

  /// Whether this device keeps a gallery. Without one nothing joins and the editor is all there
  /// is.
  bool get available => root != null && phone;

  /// The long edge of a tile's picture.
  static const pictureEdge = 512;

  static const _openKey = 'gallery.open';

  // ── What it holds ───────────────────────────────────────────────────────────────────────

  /// Everything kept, the most recently edited first.
  final List<GalleryEntry> entries = [];

  /// The rolls, the most recently shot first.
  final List<GalleryRoll> rolls = [];

  /// Photographs and movies.
  List<GalleryEntry> get photos => [for (final e in entries) if (!e.negative) e];

  /// Scanned negatives in no roll.
  List<GalleryEntry> get looseScans => [
        for (final e in entries)
          if (e.negative && e.roll == null) e,
      ];

  /// A roll's frames, in the order they joined.
  List<GalleryEntry> framesOf(GalleryRoll roll) => [
        for (final e in entries)
          if (e.roll == roll.id) e,
      ]..sort((a, b) => a.created.compareTo(b.created));

  GalleryRoll? rollOf(GalleryEntry entry) => _roll(entry.roll);

  GalleryRoll? _roll(String? id) =>
      id == null ? null : rolls.where((r) => r.id == id).firstOrNull;

  /// Photographs and negatives are listed apart once there are both.
  bool get tabbed =>
      entries.any((e) => !e.negative) && (rolls.isNotEmpty || entries.any((e) => e.negative));

  GalleryTab get tab => _tab;
  GalleryTab _tab = GalleryTab.photos;
  set tab(GalleryTab value) {
    if (value == _tab) return;
    _tab = value;
    notifyListeners();
  }

  /// The roll whose frames are listed in place of the gallery.
  GalleryRoll? get rollOpen => _rollOpen;
  GalleryRoll? _rollOpen;

  void showRoll(GalleryRoll? roll) {
    if (roll == _rollOpen) return;
    _rollOpen = roll;
    notifyListeners();
  }

  void _sort() {
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    rolls.sort((a, b) =>
        a.date != b.date ? b.date.compareTo(a.date) : b.created.compareTo(a.created));
  }

  /// Now, in milliseconds, and never the same twice: entries are ordered by it and named for it.
  int _now() => _clock = math.max(_clock + 1, DateTime.now().millisecondsSinceEpoch);
  int _clock = 0;

  String pathOf(GalleryEntry entry) => '$root/${entry.file}';
  String _recordPath(GalleryEntry entry) => '$root/entries/${entry.id}.json';
  String _picturePath(GalleryEntry entry) => '$root/entries/${entry.id}.png';

  void _write(GalleryEntry entry) => writeRecord(_recordPath(entry), entry.toJson());
  void _writeRolls() => writeRecord('$root/rolls.json', [for (final r in rolls) r.toJson()]);

  // ── Showing ─────────────────────────────────────────────────────────────────────────────

  /// Whether the gallery covers the editor. An engine that could not start says so in the
  /// editor, which then shows.
  bool get shown => available && _shown && editor.startupError == null;
  bool _shown = true;

  void _show(bool value) {
    if (value == _shown) return;
    _shown = value;
    notifyListeners();
  }

  /// The entry open in the editor, opened again when the app next starts.
  String? _openId;

  void _remember(String? id) {
    if (id == _openId) return;
    _openId = id;
    editor.settings.set(_openKey, id);
  }

  /// The shown photograph is the one to come back to. When the last one is closed in the editor
  /// there is nothing left to edit, and the gallery is back.
  void _follow() {
    if (!available) return;
    final doc = editor.active;
    if (doc != null) {
      _editing = true;
      _remember(_entryOf[doc]?.id);
    } else if (_editing && editor.documents.isEmpty && _closing == null) {
      _editing = false;
      _remember(null);
      _show(true);
    }
  }

  /// Whether the editor has had a photograph since the gallery was last shown.
  bool _editing = false;

  bool _restoring = false;

  /// Opens the entry the app was closed on. With nothing to come back to, or a photograph
  /// already opened from outside, there is nothing to do.
  Future<void> restore() async {
    // Asked before the app is laid out, it waits to learn whether this is a phone.
    _restoring = !phone;
    if (!available || editor.documents.isNotEmpty) return;
    final entry = entries.where((e) => e.id == _openId).firstOrNull;
    if (entry != null && editor.engine != null) {
      // A frame was opened from its roll, which is where closing it leads.
      _rollOpen = rollOf(entry);
      await open(entry);
    }
    if (editor.documents.isEmpty) {
      _remember(null);
      _show(true);
    }
  }

  // ── Opening and closing ─────────────────────────────────────────────────────────────────

  /// Opens an entry in the editor. `handoff` flies the tile's picture to the viewer.
  Future<void> open(GalleryEntry entry, {LibraryHandoff? handoff}) async {
    if (editor.engine == null || editor.exporting) return;
    await _closing;
    if (!entries.contains(entry)) return;
    final path = pathOf(entry);
    if (!isFile(path)) return editor.showError('${entry.name} is no longer on this device.');
    if (handoff != null) editor.library.beginHandoff(handoff);
    _show(false);
    await editor.openFiles([PhotoFile(entry.name, path: path, negative: entry.negative)]);
    // One that could not be opened leaves its message over the gallery.
    if (editor.documents.isEmpty) {
      editor.library.endHandoff();
      _show(true);
    }
  }

  /// The entry each open photograph is, and the edit the gallery last saw of it: an entry's as
  /// it was kept, otherwise the one it opened with.
  final _entryOf = Expando<GalleryEntry>('entry');
  final _seen = Expando<String>('seen');

  /// Open photographs whose tile is behind their edit.
  final Set<PhotoDocument> _behind = {};

  /// A photograph has opened in the editor (`openFiles`): one of the gallery's is known for it,
  /// a new scan joins, and a new photograph waits for its first edit.
  void opened(PhotoDocument doc) {
    if (!available) return;
    final path = doc.path, identity = doc.identity;
    final entry = entries.where((e) => pathOf(e) == path).firstOrNull ??
        (identity == null ? null : entries.where((e) => e.identity == identity).firstOrNull);
    _seen[doc] = editText(doc.edit);
    final adding = _roll(_adding);
    if (entry != null) {
      _entryOf[doc] = entry;
      // A scan already here, chosen for a roll, is filed in it.
      if (adding != null && entry.negative && pathOf(entry) != path) {
        try {
          _file(entry, adding);
        } catch (_) {
          // It stays where it is.
        }
      }
      _tab = entry.negative ? GalleryTab.negatives : GalleryTab.photos;
    } else if (isNegative(doc.edit)) {
      _queue(() async {
        if (!editor.documents.contains(doc)) return;
        await _picture(doc, await _join(doc, roll: adding));
      });
    }
    _show(false);
  }

  /// Leaves the editor for the gallery: what is open is kept, then closed.
  Future<void> closeEditor() {
    if (!available || editor.exporting) return Future.value();
    return _closing ??= _close().whenComplete(() {
      _closing = null;
      notifyListeners();
    });
  }

  /// A photograph is about to close in the editor (Close Photo): its edit is kept first.
  Future<void> leaving(PhotoDocument doc) {
    if (!available) return Future.value();
    _waiting.remove(doc);
    return _queue(() => _keep(doc, closing: true));
  }

  /// Set while the editor's photographs are kept and closed; nothing opens until they are.
  bool get closing => _closing != null;
  Future<void>? _closing;

  Future<void> _close() async {
    if (editor.importing) editor.cancelImport();
    editor
      ..endEdit()
      ..keptEdits.flush();
    _timer?.cancel();
    _waiting.clear();
    _editing = false;
    _show(true);
    await _queue(() async {
      for (final doc in [...editor.documents]) {
        await _keep(doc, closing: true);
      }
    });
    await editor.strip.clear();
    _behind.clear();
    _remember(null);
  }

  // ── Keeping ─────────────────────────────────────────────────────────────────────────────

  /// Edited photographs wait a moment, so a slider being dragged is kept once.
  final Set<PhotoDocument> _waiting = {};
  Timer? _timer;

  void _edited(EditChange change) {
    if (!available) return;
    _waiting.add(change.doc);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), keep);
  }

  /// Keeps what is waiting now (the app is going to the background).
  Future<void> keep() {
    _timer?.cancel();
    final docs = [..._waiting];
    _waiting.clear();
    return _queue(() async {
      for (final doc in docs) {
        await _keep(doc);
      }
    });
  }

  /// The gallery's work runs one piece at a time, in the order it was asked for.
  Future<void> _work = Future.value();

  Future<void> _queue(Future<void> Function() job) => _work = _work.then((_) async {
        try {
          await job();
        } catch (e) {
          editor.showError('The photograph could not be kept in the gallery. $e');
        }
      });

  /// Brings a photograph's entry up to its edit: one edited for the first time joins, one whose
  /// edit changed moves to the front, and its tile is developed again. While `closing`, a
  /// develop a newer one cancelled is asked for again.
  Future<void> _keep(PhotoDocument doc, {bool closing = false}) async {
    if (!editor.documents.contains(doc)) return;
    final text = editText(doc.edit);
    var entry = _entryOf[doc];
    if (entry == null) {
      if (text == _seen[doc]) return;
      entry = await _join(doc);
    } else if (text != _seen[doc]) {
      entry
        ..modified = _now()
        ..stock = doc.edit['stock'] as String?;
      _write(entry);
      _seen[doc] = text;
      _behind.add(doc);
      _sort();
      notifyListeners();
    }
    if (_behind.contains(doc)) await _picture(doc, entry, retries: closing ? 4 : 0);
  }

  /// Copies a photograph's file into the gallery and records it. The file it was opened from
  /// stays: the engine reads it while the photograph is open.
  Future<GalleryEntry> _join(PhotoDocument doc, {GalleryRoll? roll}) async {
    final now = _now(), id = now.toRadixString(36);
    final negative = isNegative(doc.edit);
    final folder = roll != null && negative ? 'rolls/${roll.id}' : 'photos/$id';
    final name = await copyInto('$root/$folder', doc.path, doc.name);
    final entry = GalleryEntry(
      id: id,
      file: '$folder/$name',
      created: now,
      modified: now,
      stock: doc.edit['stock'] as String?,
      video: doc.isMovie,
      negative: negative,
      identity: doc.identity,
      roll: roll != null && negative ? roll.id : null,
    );
    _write(entry);
    entries.add(entry);
    _sort();
    _entryOf[doc] = entry;
    _seen[doc] = editText(doc.edit);
    _behind.add(doc);
    _tab = negative ? GalleryTab.negatives : GalleryTab.photos;
    _follow();
    notifyListeners();
    return entry;
  }

  /// Develops a photograph small for its tile. The renderer cancels the develop in progress for
  /// a newer edit; the tile then waits for the next time it is kept, or asks again (`retries`).
  Future<void> _picture(PhotoDocument doc, GalleryEntry entry, {int retries = 0}) async {
    final engine = editor.engine;
    if (engine == null) return;
    final edit = doc.edit;
    final request = {
      ...renderRequest(
        catalogue: editor.catalogue,
        handle: doc.handle,
        edit: edit,
        stock: editor.stockById(edit['stock'] as String?),
        maxEdge: pictureEdge,
      ),
      'original': false,
      if (doc.isMovie) 'videoTime': doc.clip!.start,
    };
    for (var attempt = 0;; attempt++) {
      if (!editor.documents.contains(doc)) return;
      try {
        final bytes = (await engine.call('render', request)).bytes('preview');
        if (bytes == null || !entries.contains(entry)) return;
        await writeBytes(_picturePath(entry), bytes);
        _behind.remove(doc);
        _pictured(entry, await decodePng(bytes));
        return;
      } on FotufilmCancelled {
        if (attempt >= retries) return;
      }
    }
  }

  // ── The tiles' pictures ─────────────────────────────────────────────────────────────────

  /// The pictures read so far, the most recently shown last; the oldest make way.
  final _pictures = <String, ui.Image>{};
  static const _picturesKept = 120;

  /// Entries whose picture was asked for; one with no picture is not asked for again.
  final Set<String> _asked = {};

  /// An entry's picture, or null until it is read (listeners are told when it is).
  ui.Image? picture(GalleryEntry entry) {
    final image = _pictures.remove(entry.id);
    if (image != null) {
      _pictures[entry.id] = image;
    } else if (_asked.add(entry.id)) {
      _read(entry);
    }
    return image;
  }

  Future<void> _read(GalleryEntry entry) async {
    try {
      final bytes = await readBytes(_picturePath(entry));
      if (bytes == null) return;
      final image = await decodePng(bytes);
      // One developed meanwhile is newer.
      if (!_pictures.containsKey(entry.id) && entries.contains(entry)) _pictured(entry, image);
    } catch (_) {
      // A picture that cannot be read leaves the tile empty.
    }
  }

  void _pictured(GalleryEntry entry, ui.Image image) {
    _pictures.remove(entry.id);
    _pictures[entry.id] = image;
    while (_pictures.length > _picturesKept) {
      // A tile still showing it keeps the picture; it is read again when asked for.
      _asked.remove(_pictures.keys.first);
      _pictures.remove(_pictures.keys.first);
    }
    notifyListeners();
  }

  // ── Deleting ────────────────────────────────────────────────────────────────────────────

  /// Removes an entry: its file, its picture and its kept edit.
  Future<void> delete(GalleryEntry entry) async {
    await _closing;
    _remove(entry);
    notifyListeners();
  }

  void _remove(GalleryEntry entry) {
    if (!entries.remove(entry)) return;
    removeFile(_recordPath(entry));
    removeFile(_picturePath(entry));
    removeFile(pathOf(entry));
    removeFolder('$root/photos/${entry.id}');
    // The same photograph kept twice shares its edit.
    final identity = entry.identity;
    if (identity != null && !entries.any((e) => e.identity == identity)) {
      editor.keptEdits.forget(identity);
    }
    _pictures.remove(entry.id);
    _asked.remove(entry.id);
    if (_openId == entry.id) _remember(null);
  }

  // ── Rolls ───────────────────────────────────────────────────────────────────────────────

  GalleryRoll createRoll(String name, DateTime date) {
    final now = _now();
    final roll = GalleryRoll(
        id: now.toRadixString(36),
        name: name.trim(),
        date: date.millisecondsSinceEpoch,
        created: now);
    rolls.add(roll);
    _sort();
    _writeRolls();
    _tab = GalleryTab.negatives;
    notifyListeners();
    return roll;
  }

  void updateRoll(GalleryRoll roll, {required String name, required DateTime date}) {
    roll
      ..name = name.trim()
      ..date = date.millisecondsSinceEpoch;
    _sort();
    _writeRolls();
    notifyListeners();
  }

  /// Deletes a roll, and its frames with it or left loose in the gallery.
  Future<void> deleteRoll(GalleryRoll roll, {required bool frames}) async {
    await _closing;
    if (!rolls.contains(roll)) return;
    for (final frame in framesOf(roll)) {
      if (frames) {
        _remove(frame);
      } else {
        _file(frame, null);
      }
    }
    rolls.remove(roll);
    _writeRolls();
    removeFolder('$root/rolls/${roll.id}', onlyEmpty: true);
    if (_rollOpen == roll) _rollOpen = null;
    notifyListeners();
  }

  /// Files a scan in a roll, or takes it out of its roll (`roll` null).
  Future<void> fileIn(GalleryEntry entry, GalleryRoll? roll) async {
    await _closing;
    if (!entries.contains(entry) || !entry.negative || entry.roll == roll?.id) return;
    try {
      _file(entry, roll);
    } catch (e) {
      editor.showError('${entry.name} could not be moved. $e');
    }
    notifyListeners();
  }

  /// A frame's file lives in its roll's folder; a loose scan's in its own.
  void _file(GalleryEntry entry, GalleryRoll? roll) {
    if (entry.roll == roll?.id) return;
    final folder = roll == null ? 'photos/${entry.id}' : 'rolls/${roll.id}';
    final from = pathOf(entry);
    if (isFile(from)) {
      entry.file = '$folder/${moveInto('$root/$folder', from)}';
      removeFolder('$root/photos/${entry.id}', onlyEmpty: true);
    }
    entry.roll = roll?.id;
    _write(entry);
  }

  /// The roll scans join as they open, while its Add Frames chooses them.
  String? _adding;

  /// Runs `choose` (a chooser of scans): the negatives it opens join `roll`.
  Future<void> addFrames(GalleryRoll roll, Future<void> Function() choose) async {
    _adding = roll.id;
    try {
      await choose();
    } finally {
      _adding = null;
    }
  }
}
