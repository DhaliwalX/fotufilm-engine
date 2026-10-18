// App-wide preferences kept on this device (web/src/app-settings.js), and the editor's other
// remembered things (presets, band sets, kept edits, panel widths) under their own keys. Values
// are JSON; each setting has its default here and the stored value wins when there is one.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  /// Settings that are not kept, for tests and for a host without storage.
  AppSettings.memory() : _prefs = null;

  static Future<AppSettings> load() async {
    try {
      return AppSettings._(await SharedPreferencesWithCache.create(
          cacheOptions: const SharedPreferencesWithCacheOptions()));
    } catch (_) {
      return AppSettings.memory();
    }
  }

  final SharedPreferencesWithCache? _prefs;
  final Map<String, Object?> _memory = {};

  static const prefix = 'fotufilm.setting.';

  /// app-settings.js `APP_SETTINGS`.
  static const defaults = <String, Object?>{
    'autoFilm': false,
    'startingFilm': null,
    'startingFormat': null,
    'grainModel': 'clump',
    'halationModel': 'legacy',
    'estimatedHalation': false,
    'couplerReach': 1,
    'couplerRedGreen': null,
    'couplerGreenBlue': null,
    'couplerSelf': 1,
    'receiverBands': null,
    'photoHDR': false,
    'videoHDR': false,
    'videoBitrate': 'automatic',
    'videoProcessing': 'full',
    'videoPlaybackQuality': 'fine',
    'photoQuality': 'accurate',
    'lastPhotoExport': null,
    'lastVideoExport': null,
    'updateChecksAutomatically': true,
    'updatePrereleases': false,
    'updateLastCheck': null,
    'updateSkipped': null,
    'pluginOfferDeclined': null,
  };

  /// A value: the stored one, else the default.
  T? get<T>(String key) {
    if (_memory.containsKey(key)) return _memory[key] as T?;
    final text = _prefs?.getString('$prefix$key');
    Object? value = defaults[key];
    if (text != null) {
      try {
        value = jsonDecode(text);
      } catch (_) {}
    }
    _memory[key] = value;
    return value as T?;
  }

  /// Whether `key` holds a value of its own rather than its default.
  bool isStored(String key) =>
      _prefs?.containsKey('$prefix$key') ?? (_memory.containsKey(key) && _memory[key] != null);

  void set(String key, Object? value) {
    _memory[key] = value;
    final prefs = _prefs;
    if (prefs != null) {
      if (value == null && !defaults.containsKey(key)) {
        prefs.remove('$prefix$key');
      } else {
        prefs.setString('$prefix$key', jsonEncode(value));
      }
    }
    notifyListeners();
  }

  /// Every setting back to its default (Settings › Reset All Settings); other kept things stay.
  void resetAll() {
    for (final key in defaults.keys) {
      _memory.remove(key);
      _prefs?.remove('$prefix$key');
    }
    notifyListeners();
  }
}
