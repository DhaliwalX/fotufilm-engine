// Lens correction (web/src/LensControls.jsx, LensProfileLibrary.jsx, lens-correction.js and
// backend/desktop/lenses.js): the lens profiles imported on this device, and the plan the engine
// makes for a photograph's lens setting, whose note the Lens section shows. The correction itself
// develops from the edit's `lens`.
import 'dart:convert';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/foundation.dart';

import 'editor.dart';

/// A photograph's lens setting before it is changed (lens-correction.js `defaultLens`).
const Json defaultLens = {
  'enabled': false,
  'amount': 1,
  'profileID': null,
  'distortion': 0,
  'vignetting': 0,
  'redCyan': 0,
  'blueYellow': 0,
};

/// The lens sliders: catalogue field to the key in the edit's `lens`.
const lensFields = {
  'lensDistortion': 'distortion',
  'lensVignetting': 'vignetting',
  'lensRedCyan': 'redCyan',
  'lensBlueYellow': 'blueYellow',
};

/// Whether a lens setting differs from the plain correction, so Reset Lens has work to do.
bool hasLensAdjustments(Map lens) =>
    (lens['amount'] ?? 1) != 1 ||
    lens['profileID'] != null ||
    lensFields.values.any((key) => (lens[key] ?? 0) != 0);

class LensCorrection extends ChangeNotifier {
  LensCorrection(this.editor);
  final EditorModel editor;

  /// The imported profiles, `{id, maker, model, …}`.
  List<Json> profiles = const [];
  String? catalogueError;
  int _revision = 0;
  Future<void>? _loading;

  /// Reads the imported catalogue once; Import and Remove read it again.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final engine = editor.engine;
    if (engine == null) {
      _loading = null;
      return;
    }
    try {
      final answer = await engine.call('lensCatalogue');
      profiles = ((answer.value as List?) ?? const []).cast<Json>();
      catalogueError = null;
    } catch (e) {
      _loading = null;
      catalogueError = '$e';
    }
    _revision++;
    notifyListeners();
  }

  /// Imports the profiles of a lens-profile JSON catalogue; answers how many there were.
  Future<int> import(XFile file) async {
    if (await file.length() > 6 * 1024 * 1024) {
      throw const LensError('Choose a lens catalogue smaller than 6 MB.');
    }
    Object? profiles;
    try {
      profiles = jsonDecode(await file.readAsString());
    } catch (_) {
      throw const LensError('Choose a valid Fotufilm lens-profile JSON catalogue.');
    }
    if (profiles is! List || profiles.isEmpty) {
      throw const LensError('Choose a Fotufilm lens-profile JSON catalogue.');
    }
    final answer = await editor.engine!.call('importLensCatalogue', {'profiles': profiles});
    _loading = null;
    await load();
    return (answer.value as num).toInt();
  }

  Future<void> remove() async {
    await editor.engine!.call('removeLensCatalogue');
    _loading = null;
    await load();
  }

  // ── The plan for the shown photograph ────────────────────────────────────────────────────

  String? _planKey;

  /// The engine's plan (`note`, `measurement`, …) for the shown setting, once it has answered.
  Json? plan;
  String? planError;

  /// Asks for the plan of `lens` on `doc` when its switch or profile changed (the sliders do not
  /// change the plan's note), as LensControls.jsx does.
  void follow(PhotoDocument doc, Map lens) {
    final engine = editor.engine;
    final key = '${doc.handle}|${lens['enabled']}|${lens['profileID']}|$_revision';
    if (engine == null || key == _planKey) return;
    _planKey = key;
    plan = null;
    planError = null;
    if (lens['enabled'] != true) return;
    engine.call('lensPlan', {
      'handle': doc.handle,
      'lens': {...defaultLens, 'enabled': true, 'profileID': lens['profileID']},
    }).then((answer) {
      if (_planKey != key) return;
      plan = answer.json;
      notifyListeners();
    }, onError: (Object e) {
      if (_planKey != key) return;
      planError = '$e';
      notifyListeners();
    });
  }
}

class LensError implements Exception {
  const LensError(this.message);
  final String message;
  @override
  String toString() => message;
}
