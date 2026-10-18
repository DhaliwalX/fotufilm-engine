// Receiver bands: the peaks of the three bands Digital Reference reads a colour film through, the
// sets saved under a name on this device, and the bands new photographs start on (the
// `receiverBands` setting). Bands are `{red, green, blue}` in nm; a saved set adds its `name`.
import 'catalogue.dart';
import 'settings.dart';

/// The profile fields of the red, green and blue bands.
const bandFields = ['screenRedBand', 'screenGreenBand', 'screenBlueBand'];
const bandKeys = ['red', 'green', 'blue'];

/// The peaks of an edit's profile, the paper's where a band is unset.
Json editBands(Map? profile, Json paper) => {
      for (var i = 0; i < 3; i++) bandKeys[i]: profile?[bandFields[i]] ?? paper[bandKeys[i]],
    };

bool sameBands(Map? a, Map? b) =>
    a != null && b != null && bandKeys.every((k) => a[k] != null && a[k] == b[k]);

/// The profile with its bands set to `bands`, or cleared back to the paper's when null.
Json withBands(Map profile, Map? bands) {
  final next = Map<String, dynamic>.from(profile);
  for (var i = 0; i < 3; i++) {
    final value = bands?[bandKeys[i]];
    if (value == null) {
      next.remove(bandFields[i]);
    } else {
      next[bandFields[i]] = value;
    }
  }
  return next;
}

class BandSets {
  BandSets(this.catalogue, this.settings);
  final Catalogue catalogue;
  final AppSettings settings;

  /// Kept apart from the app settings, so Reset All Settings leaves them.
  static const key = 'receiverBandSets';

  /// The three bands' controls, for their titles, help and ranges.
  List<Json> get controls => [
        for (final field in bandFields)
          catalogue.profileControls.firstWhere((c) => c['field'] == field),
      ];

  /// The paper's own peaks.
  Json get paper => {
        for (var i = 0; i < 3; i++) bandKeys[i]: Catalogue.profileDefault(controls[i]),
      };

  /// The saved sets, sorted by name.
  List<Json> get sets => [
        for (final set in (settings.get<List>(key) ?? const []))
          if (set is Map && set['name'] is String && bandKeys.every((k) => set[k] is num))
            Json.from(set),
      ];

  /// Saves `bands` under `name`, replacing a set of the same name.
  void save(String name, Map bands) {
    final next = [
      ...sets.where((s) => s['name'] != name),
      {'name': name, for (final k in bandKeys) k: bands[k]},
    ]..sort((a, b) => _compareNames(a['name'] as String, b['name'] as String));
    settings.set(key, next);
  }

  void delete(String name) => settings.set(key, sets.where((s) => s['name'] != name).toList());

  /// The bands new photographs start on, or null for the paper's.
  Json? get starting => (settings.get<Map>('receiverBands'))?.cast<String, dynamic>();
  set starting(Map? bands) =>
      settings.set('receiverBands', bands == null ? null : {for (final k in bandKeys) k: bands[k]});

  /// A new photograph's edit on the starting bands.
  void start(Json edit) {
    final bands = starting;
    if (bands != null) edit['profile'] = withBands(edit['profile'] as Map, bands);
  }
}

/// Names in order with their numbers read as numbers ("Set 2" before "Set 10").
int _compareNames(String a, String b) {
  final digits = RegExp(r'\d+|\D+');
  final pa = digits.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final pb = digits.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final na = int.tryParse(pa[i]), nb = int.tryParse(pb[i]);
    final order = na != null && nb != null ? na.compareTo(nb) : pa[i].compareTo(pb[i]);
    if (order != 0) return order;
  }
  return pa.length.compareTo(pb.length);
}
