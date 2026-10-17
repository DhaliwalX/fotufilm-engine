// Auto Adjust (web/src/auto-adjustment.js, useAutoAdjustment.js): a mode, not a one-off. While it
// is on, the engine fits exposure, highlights and shadows inside the film's latitude, and fits
// them again when the latitude (the film, its channel contrast match) or the framing changes. A
// manual tone edit, an undo or a paste turns it off; the solved values stay, as ordinary steps of
// the history. A generation number keeps an old measurement from landing on a newer edit.
import 'dart:async';

import 'editor.dart';
import 'saved_edits.dart';

/// The film's latitude changed: the film, or how its channels are matched.
bool autoWindowChanged(Json before, Json after) =>
    before['stock'] != after['stock'] ||
    ((before['profile'] as Map)['printCorrection'] ?? 0) !=
        ((after['profile'] as Map)['printCorrection'] ?? 0);

/// The framing changed, so the photograph measures differently.
bool autoFrameChanged(Json before, Json after) => const [
      'crop', 'cropShape', 'rotation', 'flip', 'straighten', 'perspectiveV', 'perspectiveH', //
    ].any((key) => editText({key: before[key]}) != editText({key: after[key]}));

/// Exposure, highlights or shadows were set by hand.
bool autoToneChanged(Json before, Json after) => const ['ev', 'highlights', 'shadows']
    .any((key) => (before['params'] as Map)[key] != (after['params'] as Map)[key]);

class AutoAdjustment {
  AutoAdjustment(this.editor) {
    editor.editListeners.add(_changed);
    editor.addListener(_followShown);
  }

  final EditorModel editor;

  /// Whether the mode is on, whether it is measuring, and what it says while it does.
  bool active = false, busy = false;
  String? status;

  int _generation = 0;
  bool _applying = false;
  Timer? _again;
  PhotoDocument? _shown;

  /// A photograph with a scene to meter: not a negative printed through a film, nor a film whose
  /// settings are fixed.
  bool get available {
    final doc = editor.active;
    if (doc == null || editor.engine == null || editor.exporting) return false;
    final edit = doc.edit;
    if (edit['negative'] != null && edit['stock'] != null) return false;
    return !fixedStockSettings(editor.selectedStock);
  }

  void _publish(bool on, bool measuring, String? text) {
    active = on;
    busy = measuring;
    status = text;
    editor.notify();
  }

  void toggle() {
    if (active) {
      cancel();
    } else {
      run(editor.edit);
    }
  }

  /// Turns the mode off and drops a measurement in flight.
  void cancel({bool notify = true}) {
    _generation++;
    _again?.cancel();
    if (notify && (active || busy)) _publish(false, false, null);
  }

  /// Another photograph shown turns the mode off.
  void _followShown() {
    final shown = editor.active;
    if (identical(shown, _shown)) return;
    _shown = shown;
    if (active || busy) scheduleMicrotask(cancel);
  }

  void _changed(EditChange change) {
    if (_applying || change.doc != editor.active) return;
    if (change.restoring || change.kind != 'edit') {
      cancel();
    } else if (autoToneChanged(change.before, change.doc.edit)) {
      cancel();
    } else if (active &&
        (autoWindowChanged(change.before, change.doc.edit) ||
            autoFrameChanged(change.before, change.doc.edit))) {
      // A crop being dragged measures once it pauses, not for every movement.
      _again?.cancel();
      _again = Timer(const Duration(milliseconds: 250), _rerun);
    } else if (busy) {
      cancel();
    }
  }

  void _rerun() {
    final doc = editor.active;
    if (!active || doc == null) return;
    if (doc.history.group != null) {
      _again = Timer(const Duration(milliseconds: 250), _rerun);
      return;
    }
    run(doc.edit);
  }

  Future<void> run(Json edit) async {
    final doc = editor.active, engine = editor.engine;
    if (doc == null || engine == null || !available) {
      // A film with fixed settings has no latitude to fit: the mode goes off.
      cancel();
      return;
    }
    cancel(notify: false);
    final generation = _generation;
    _publish(true, true, 'Measuring the photograph');
    bool current() => generation == _generation && editor.active == doc;
    try {
      final answer = await engine.call('autoAdjust', {'handle': doc.handle, 'edit': edit});
      if (!current()) return;
      final params = Map<String, dynamic>.from(doc.edit['params'] as Map);
      for (final key in const ['ev', 'highlights', 'shadows']) {
        final value = answer.json[key];
        if (value is num) params[key] = value.toDouble();
      }
      _applying = true;
      try {
        editor.endEdit();
        editor.patch({'params': params});
      } finally {
        _applying = false;
      }
      _publish(true, false, null);
    } catch (e) {
      if (!current()) return;
      cancel();
      editor.showError('Auto Adjust failed. $e');
    }
  }
}
