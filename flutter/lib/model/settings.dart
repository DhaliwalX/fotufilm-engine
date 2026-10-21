// App-wide preferences kept on this device, and the editor's other remembered things (presets, band
// sets, kept edits, panel widths) under their own keys. Values are JSON; each setting has its
// default here and the stored value wins when there is one.
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

  /// A value: the stored one, else the default. One of another type reads as the default.
  T? get<T>(String key) {
    if (!_memory.containsKey(key)) _memory[key] = _stored(key);
    return switch (_memory[key]) {
      final T value => value,
      _ => defaults[key] is T ? defaults[key] as T : null,
    };
  }

  /// What is kept under `key`: JSON text, as [set] writes it. The browser editor before this one
  /// kept the same keys in localStorage as plain JSON, which the web store hands back decoded: a
  /// map, a number, or a string that is not JSON.
  Object? _stored(String key) {
    final stored = _prefs?.get('$prefix$key');
    if (stored is! String) return stored ?? defaults[key];
    try {
      return jsonDecode(stored);
    } on FormatException {
      return stored;
    }
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
