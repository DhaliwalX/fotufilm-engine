// The panels either side of the picture: each as wide as it was left, kept between launches, and
// given back to the picture as the window narrows. Below 834 points the editor takes the phone's
// stacked layout: the film list and the inspector become docks under the picture, opened one at a
// time from the rail.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ui/theme/metrics.dart';
import 'editor.dart';

/// The widest window that takes the compact layout (`(max-width: 833px)`).
const compactMaxWidth = 833.0;

enum PanelSide { film, inspector }

/// A side's initial, least and greatest width.
({double initial, double min, double max}) panelBounds(PanelSide side) => switch (side) {
      PanelSide.film => (
          initial: Metrics.filmWidth,
          min: Metrics.filmMin,
          max: Metrics.filmMax,
        ),
      PanelSide.inspector => (
          initial: Metrics.inspectorWidth,
          min: Metrics.inspectorMin,
          max: Metrics.inspectorMax,
        ),
    };

/// `width` for `side`, inside its own bounds and leaving the picture its room beside `other`, the
/// other panel's width, in a window `window` across. A panel keeps its least width even in a
/// window too narrow for all three.
double clampedWidth(PanelSide side, double? width, double other, double? window) {
  final b = panelBounds(side);
  final room = window != null && window.isFinite ? window - other - Metrics.pictureMin : b.max;
  final asked = width != null && width.isFinite ? width : b.min;
  return math.max(b.min, math.min(b.max, math.min(room, asked))).roundToDouble();
}

/// The widths shown for the widths asked for: a narrow window takes room back for the picture
/// from the inspector first, then the film list.
({double film, double inspector}) shownWidths(
    ({double film, double inspector}) preferred, double? window) {
  final inspector = clampedWidth(PanelSide.inspector, preferred.inspector, preferred.film, window);
  final film = clampedWidth(PanelSide.film, preferred.film, inspector, window);
  return (film: film, inspector: inspector);
}

/// The widths kept from the last visit, each inside its bounds; the defaults otherwise.
({double film, double inspector}) keptWidths(Object? kept) {
  double side(PanelSide s) {
    final b = panelBounds(s);
    final width = kept is Map ? kept[s.name] : null;
    return width is num && width.isFinite ? width.toDouble().clamp(b.min, b.max) : b.initial;
  }

  return (film: side(PanelSide.film), inspector: side(PanelSide.inspector));
}

class PanelLayout extends ChangeNotifier {
  PanelLayout(this.editor) : preferred = keptWidths(editor.settings.get('panelWidths'));
  final EditorModel editor;

  /// Where the widths are kept, apart from the settings so Reset All Settings leaves them.
  static const key = 'panelWidths';

  /// The widths asked for, which a window too narrow for them only hides until it widens again.
  ({double film, double inspector}) preferred;

  /// The window's width, as the workspace last laid it out.
  double? window;

  bool compact = false;

  ({double film, double inspector}) get widths => shownWidths(preferred, window);

  /// The workspace's width changed: a window narrowed into the compact layout closes both docks.
  void layOut(double width) {
    window = width;
    final next = width <= compactMaxWidth;
    if (next == compact) return;
    compact = next;
    if (compact) {
      if (editor.filmOpen) editor.toggleFilm();
      if (editor.inspectorOpen) editor.toggleInspector();
    }
    notifyListeners();
  }

  /// Sets `side`'s width as far as the window allows; `keep` remembers both for the next visit,
  /// as a drag's end does.
  void setWidth(PanelSide side, double width, {bool keep = false}) {
    final shown = widths;
    final other = side == PanelSide.film ? shown.inspector : shown.film;
    final next = clampedWidth(side, width, other, window);
    preferred = side == PanelSide.film
        ? (film: next, inspector: preferred.inspector)
        : (film: preferred.film, inspector: next);
    if (keep) keepWidths();
    notifyListeners();
  }

  void keepWidths() =>
      editor.settings.set(key, {'film': preferred.film, 'inspector': preferred.inspector});

  /// A panel chosen from the rail: in the compact layout the Film panel is the film list's dock,
  /// and the other panels the inspector's.
  void choosePanel(Panel panel) {
    editor.endEdit();
    if (!compact) return editor.setPanel(panel);
    final films = panel == Panel.film;
    editor.setPanel(panel);
    if (films && editor.inspectorOpen) editor.toggleInspector();
    if (editor.filmOpen != films) editor.toggleFilm();
  }

  /// The compact rail's Film button: closes the film dock when it is open.
  void railPressed(Panel panel) {
    if (compact && editor.filmOpen && panel == Panel.film) {
      editor.toggleFilm();
    } else {
      choosePanel(panel);
    }
  }

  /// A dock's close button.
  void dismiss(PanelSide side) {
    editor.endEdit();
    if (side == PanelSide.film && editor.filmOpen) editor.toggleFilm();
    if (side == PanelSide.inspector && editor.inspectorOpen) editor.toggleInspector();
  }

  /// The film list's Film settings button: the Film panel in the inspector's dock.
  void filmSettings() {
    editor.setPanel(Panel.film);
    if (editor.filmOpen) editor.toggleFilm();
    if (!editor.inspectorOpen) editor.toggleInspector();
  }

  /// Show or hide the inspector; in the compact layout the film dock gives way.
  void toggleInspector() {
    editor.toggleInspector();
    if (compact && editor.filmOpen) editor.toggleFilm();
  }
}
