// A photograph's edit, in the web editor's JSON shape (web/src/editor-state.js `defaultEdit`), so
// it goes to the engine as it is.
import 'dart:convert';

import 'catalogue.dart';

/// A new edit prints on what its film prints on (Match Film): `filmMedium` is the film's own, the
/// library entry's (`WebStockCatalogue.entries`).
Json defaultEdit(Catalogue catalogue, [String? stock, String? filmMedium]) => {
      'stock': stock,
      'format': null,
      'profile': <String, dynamic>{},
      'filters': <dynamic>[],
      'lens': {
        'enabled': false,
        'amount': 1,
        'profileID': null,
        'distortion': 0,
        'vignetting': 0,
        'redCyan': 0,
        'blueYellow': 0,
      },
      'filterMetering': 'throughTheLens',
      'medium': filmMedium,
      'mediumFollowsFilm': true,
      'rawCorrections': true,
      'printFrame': 'none',
      'printFrameEdgePrinting': true,
      'printFrameNumber': 1,
      'printFrameFraming': [0, 0],
      'digitalReference': 'auto-levels',
      'halationModel': 'legacy',
      'sceneLight': 'unspecified',
      'selective': null,
      'params': {for (final s in catalogue.sliders) s.key: s.def},
      'gradeSpace': false,
      'localTone': true,
      'seed': 0,
      'rotation': 0,
      'flip': false,
      'straighten': 0,
      'perspectiveV': 0,
      'perspectiveH': 0,
      'cropShape': 'rectangle',
      'crop': [
        [0, 0],
        [1, 0],
        [1, 1],
        [0, 1],
      ],
      'ratio': 'free',
      'negative': null,
    };

/// The medium `edit` keeps when its film becomes `stock`: the film's own while it follows the
/// film, else the one it names where the next film offers it, else the film's default (null).
String? mediumOnFilm(Json edit, Json? stock) {
  if (edit['mediumFollowsFilm'] == true) return stock?['filmMedium'] as String?;
  final media = ((stock?['media'] as List?) ?? const []).map((m) => (m as Map)['id']);
  return media.contains(edit['medium']) ? edit['medium'] as String? : null;
}

/// A deep copy, so a step of the history never shares a map with the next.
Json copyEdit(Json edit) => jsonDecode(jsonEncode(edit)) as Json;

/// What a film-row thumbnail develops: the edit on another film, without grain or halation.
Json thumbnailEdit(Json edit, String? stock) {
  final next = copyEdit(edit);
  next['stock'] = stock;
  next['halationModel'] = 'legacy';
  (next['profile'] as Map)['halation'] = 0;
  (next['params'] as Map)['grain'] = 0;
  return next;
}

/// The render request the editor sends the engine.
Json renderRequest({
  required Catalogue catalogue,
  required int handle,
  required Json edit,
  required Json? stock,
  required int? maxEdge,
  bool draft = false,
  String? haveOriginal,
}) {
  final controls = catalogue.profileRequestControls(edit, stock);
  controls['digitalReference'] = edit['digitalReference'] ?? 'auto-levels';
  return {
    'handle': handle,
    'previewQuality': draft ? 'interactive' : 'still',
    'original': true,
    'draft': draft,
    'edit': edit,
    'maxEdge': maxEdge,
    'cropMode': false,
    'printFrame': null,
    'profileRequest': {
      'controls': controls,
      'format': edit['format'],
      'medium': edit['medium'],
      'filters': edit['filters'],
      'filterMetering': edit['filterMetering'],
      'sceneKelvin': catalogue.sourceIlluminant(edit),
    },
    'haveOriginal': ?haveOriginal,
  };
}

/// Two edits equal as the engine would read them.
bool sameEdit(Json a, Json b) => jsonEncode(a) == jsonEncode(b);
