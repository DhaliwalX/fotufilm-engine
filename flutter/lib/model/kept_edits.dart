// Every photograph keeps its last edit, as the Mac app's shelf does (web/src/editor/
// useSavedEdits.js, saved-edits.js): a file opened again starts where it was left. An edit is
// kept as text under the identity the engine answers for the file (`importPath`'s `identity`,
// the contents' digest, so a renamed or moved copy keeps it), in the app's settings. Save Edits…
// and Load Edits… write and read the same text as a file (useFilmActions.js).
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'editor.dart';
import 'saved_edits.dart';

class KeptEdits {
  KeptEdits(this.editor) {
    editor.editListeners.add(_edited);
    // What waits is kept before the app quits or goes to the background.
    // The listener stays registered with the binding for the app's life.
    AppLifecycleListener(onInactive: flush, onExitRequested: () async {
      flush();
      return AppExitResponse.exit;
    });
  }

  final EditorModel editor;

  static const _prefix = 'keptEdit:';

  /// The edit each photograph opened with, and the text last kept for it: returning an
  /// untouched photograph to its opening edit forgets the kept one rather than keeping defaults.
  final _baselines = Expando<({String text, bool saved})>('baseline');
  final _last = Expando<String>('kept');

  ({String key, String? text})? _pending;
  Timer? _timer;

  String? _load(String key) => editor.settings.get<String>('$_prefix$key');
  void _save(String key, String? text) => editor.settings.set('$_prefix$key', text);

  /// A photograph's first edit: the one kept under `key`, else a new photograph's (the starting
  /// film and format of the settings on the film shown now). A kept edit that no longer fits (a
  /// film since removed) is reported and the photograph opens fresh.
  ({Json edit, bool saved}) startingEdit(String? key, String? currentFilm) {
    final text = key == null ? null : _load(key);
    if (text != null) {
      try {
        return (edit: restoreEdit(text, editor.catalogue, editor.stocks), saved: true);
      } on EditProblem catch (e) {
        editor.error = 'The saved edit was not restored. ${e.message}';
      }
    }
    return (
      edit: newPhotoEdit(editor.catalogue, editor.settings, currentFilm,
          editor.stocks.map((s) => s['id'] as String)),
      saved: false,
    );
  }

  /// A photograph has opened with `doc.edit`, kept (`saved`) or new.
  void opened(PhotoDocument doc, {required bool saved}) {
    final text = editText(doc.edit);
    _baselines[doc] = (text: text, saved: saved);
    _last[doc] = text;
  }

  void _edited(EditChange change) {
    final doc = change.doc, key = doc.identity;
    final baseline = _baselines[doc];
    if (key == null || baseline == null) return;
    final text = editText(doc.edit);
    if (_last[doc] == text) return;
    _last[doc] = text;
    if (_pending != null && _pending!.key != key) flush();
    _pending = (key: key, text: text == baseline.text && !baseline.saved ? null : text);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), flush);
  }

  /// Keeps what is waiting now (the app is quitting, another photograph was edited).
  void flush() {
    _timer?.cancel();
    final job = _pending;
    _pending = null;
    if (job != null) _save(job.key, job.text);
  }

  /// Keeps the edit of a photograph other than the one shown (a paste onto several).
  void keep(PhotoDocument doc) {
    final key = doc.identity;
    if (key == null) return;
    final text = editText(doc.edit);
    _last[doc] = text;
    _save(key, text);
  }

  // ── Save Edits… and Load Edits… ─────────────────────────────────────────────────────────

  static const _types = [XTypeGroup(label: 'JSON', extensions: ['json'])];

  /// A name for the file: the photograph's, cleaned (file-download.js `cleanName`).
  static String fileName(String photo) {
    var name = photo
        .replaceFirst(RegExp(r'\.[^.]+$'), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '-');
    if (name.length > 100) name = name.substring(0, 100);
    return '${name.isEmpty ? 'photo' : name}.fotufilm-web.json';
  }

  /// Writes the shown photograph's edit where the save panel says.
  Future<void> saveFile() async {
    final doc = editor.active;
    if (doc == null) return;
    final location =
        await getSaveLocation(suggestedName: fileName(doc.name), acceptedTypeGroups: _types);
    if (location != null) await writeFile(location.path);
  }

  Future<void> writeFile(String path) async {
    final doc = editor.active;
    if (doc == null) return;
    try {
      await File(path).writeAsString(editFileText(doc.edit));
    } catch (e) {
      editor.showError('The edit could not be saved. $e');
    }
  }

  /// Reads an edit file onto the shown photograph, as one step Undo reverses.
  Future<void> loadFile() async {
    if (editor.active == null) return;
    final file = await openFile(acceptedTypeGroups: _types);
    if (file != null) await readFile(file.readAsString);
  }

  Future<void> readFile(Future<String> Function() read) async {
    if (editor.active == null) return;
    try {
      final edit = restoreEdit(await read(), editor.catalogue, editor.stocks);
      if (editor.active != null) editor.restore(edit);
    } on EditProblem catch (e) {
      editor.showError(e.message);
    } on FileSystemException catch (e) {
      editor.showError(e.message);
    }
  }
}
