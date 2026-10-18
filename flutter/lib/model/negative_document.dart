// A scanned negative opened as a document (web/src/negative-document.js): its edit is any
// photograph's with `negative` set, read as the edit's film and printed through the edit's own
// print by the host (Sources/FotufilmHost/HostService+NegativeScan.swift). With no film (Normal)
// the scan reads as a plain positive. These are the rules, without state.
import 'catalogue.dart';

/// How the scan is read: the clear film it is measured against (null to estimate it), the light
/// frame that evens its light, the roll's colour it is balanced on, how far the crosstalk between
/// the scan's channels and the film's dyes is undone, and the light it was scanned under ("white",
/// or "rgb" for red, green and blue LED exposures merged into one scan).
Json newNegative([String scanLight = 'white']) => {
      'border': null,
      'lightFrame': null,
      'roll': null,
      'crosstalk': 0,
      'scanLight': scanLight,
    };

/// The inspector panels a negative read as a film offers (`NEGATIVE_PANELS`).
const negativePanelIds = ['film', 'light', 'print', 'roll', 'crop'];

bool isNegative(Json? edit) => edit?['negative'] != null;

/// Whether an edit is a scanned negative read as a film, printed from its densities.
bool printsNegative(Json? edit) => isNegative(edit) && edit!['stock'] != null;

/// Whether an edit offers the panel `id`: a printed negative offers its reading, light, print,
/// roll and framing; any other photograph offers every panel but the roll.
bool offersPanel(Json? edit, String id) {
  if (id == 'roll') return isNegative(edit);
  return !printsNegative(edit) || negativePanelIds.contains(id);
}

/// The inspector's tabs for an edit, from the editor's (`documentPanels`): a negative adds the
/// Roll, and one read as a film keeps only what it offers. Ids, in order.
List<String> documentPanelIds(Json? edit, List<String> tabs) => [
      for (final id in [...tabs, if (isNegative(edit)) 'roll'])
        if (offersPanel(edit, id)) id,
    ];

/// Whether a film has a negative to read a scan as: slides and papers do not.
bool readsNegative(Json? stock) => stock?['readsNegative'] == true;

/// The film a new negative opens on: the first film its base looks like, else the film already
/// chosen, else the first film that reads negatives.
String? negativeStartingStock(Json? scan, List<Json> stocks, String? current) {
  final ids = [for (final s in stocks) if (readsNegative(s)) s['id'] as String];
  final suggestions = ((scan?['suggestions'] as List?) ?? const []).cast<Map>();
  for (final suggestion in suggestions) {
    for (final film in ((suggestion['films'] as List?) ?? const []).cast<Map>()) {
      if (ids.contains(film['id'])) return film['id'] as String;
    }
  }
  if (ids.contains(current)) return current;
  return ids.firstOrNull;
}

/// "Gold 200", "Vision3 500T or CineStill 800T", "Tri-X 400 and 7 similar films".
String suggestionName(Map suggestion) {
  final films = ((suggestion['films'] as List?) ?? const []).cast<Map>();
  return films.length > 2
      ? '${films.first['name']} and ${films.length - 1} similar films'
      : films.map((f) => f['name']).join(' or ');
}

// ── Rolls ───────────────────────────────────────────────────────────────────────────────────

/// The roll a photograph at `path` belongs to: its directory, or null for one known by name only.
String? rollOf(String? path) {
  final slash = path?.lastIndexOf('/') ?? -1;
  return slash < 0 ? null : path!.substring(0, slash);
}

/// The indices of `paths` on the roll of `active`, `active` among them, in order: the others must
/// be negatives (`negative[i]`).
List<int> rollIndices(List<String> paths, List<bool> negative, int active) {
  if (active < 0 || active >= paths.length) return const [];
  final roll = rollOf(paths[active]);
  if (roll == null) return const [];
  return [
    for (var i = 0; i < paths.length; i++)
      if (rollOf(paths[i]) == roll && (i == active || negative[i])) i,
  ];
}

// Densest ends too thin to tell a colour from, as ApproximateNegativeScan.balance holds them.
const _readable = 0.05;

bool _readableEnd(List? dense) =>
    dense != null &&
    dense.length == 3 &&
    dense.every((v) => v is num && v.isFinite && v > _readable);

/// A roll's colour (ApproximateNegativeScan.RollBalance): over the frames whose densest ends can
/// be read, the median of each end's red and blue density per unit of its green. Null when fewer
/// than two frames can be read.
Json? rollBalance(List<List?> denseEnds) {
  final frames = [
    for (final d in denseEnds)
      if (_readableEnd(d)) [for (final v in d!) (v as num).toDouble()],
  ];
  if (frames.length < 2) return null;
  double median(List<double> values) {
    values.sort();
    final middle = values.length >> 1;
    return values.length.isOdd ? values[middle] : (values[middle - 1] + values[middle]) / 2;
  }

  return {
    'colour': [
      for (final c in const [0, 2]) median([for (final d in frames) d[c] / d[1]]),
    ],
    'frames': frames.length,
  };
}

// ── Show Negative ───────────────────────────────────────────────────────────────────────────

const negativeMedium = 'negative';

/// Whether the film has a negative to show instead of the edit's output: a reversal film has
/// none, no film has none, and a negative already chosen as the medium needs no switch.
bool canShowNegative(Json edit, Json? stock) {
  final media = ((stock?['media'] as List?) ?? const []).cast<Map>();
  if (edit['stock'] == null || !media.any((m) => m['id'] == negativeMedium)) return false;
  return (edit['medium'] ?? stock!['defaultMedium']) != negativeMedium;
}

/// The edit the canvas develops while the negative is shown.
Json negativeViewEdit(Json edit, Json? stock, bool shown) =>
    shown && canShowNegative(edit, stock) ? {...edit, 'medium': negativeMedium} : edit;

// ── Trichromatic merges ─────────────────────────────────────────────────────────────────────

/// What a trichromatic merge left out, a sentence each: frames it could not merge, blank
/// exposures, exposures under white light, repeats and loosely lined-up frames.
String trichromaticNotes(Json merged) {
  List<String> names(String key) => ((merged[key] as List?) ?? const []).cast<String>();
  String list(List<String> n) => n.join(', ');
  final blanks = names('blanks'), others = names('others');
  final repeats = names('repeats'), loose = names('loose');
  return [
    for (final failure in ((merged['failures'] as List?) ?? const []).cast<Map>())
      '${list(((failure['sources'] as List?) ?? const []).cast<String>())}: ${failure['reason']}',
    if (blanks.isNotEmpty) 'Left out as blank: ${list(blanks)}.',
    if (others.isNotEmpty) 'Left out, not under one light: ${list(others)}.',
    if (repeats.isNotEmpty) 'Left out, repeated by a later exposure: ${list(repeats)}.',
    if (loose.isNotEmpty) 'Lined up loosely, so colours may fringe: ${list(loose)}.',
  ].join(' ');
}
