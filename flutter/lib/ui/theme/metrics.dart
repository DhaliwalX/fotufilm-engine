// Every size and space in the editor, in one place: the compact desktop layout of the web editor
// (40 px toolbar, compact disclosures, the value at the end of each slider, shorter film rows).
// Change spacing here, not in the widgets.
import 'package:flutter/widgets.dart';

abstract final class Metrics {
  // ── Window ─────────────────────────────────────────────────────────────────────────────────
  static const toolbarHeight = 40.0;
  static const toolbarPadding = 8.0;

  /// Room left of the brand for the macOS traffic lights, which sit in the toolbar.
  static const trafficLightInset = 74.0;

  /// The leading toolbar group's least width (toolbar.css `.toolbar-leading`).
  static const toolbarLeadingWidth = 224.0;
  static const toolbarGap = 2.0;

  // ── Panels ─────────────────────────────────────────────────────────────────────────────────
  static const filmWidth = 236.0, filmMin = 180.0, filmMax = 480.0, filmCollapsed = 52.0;
  static const inspectorWidth = 320.0, inspectorMin = 280.0, inspectorMax = 600.0;
  static const railWidth = 40.0;
  static const pictureMin = 420.0;
  static const resizerHit = 8.0;

  // ── Compact layout (styles/phone-layout.css, phone-controls.css) ────────────────────────────
  static const compactToolbarRow = 48.0;
  static const compactTouch = 44.0;
  static const compactRail = 60.0;
  static const compactRailButton = 52.0;
  static const compactFilmDock = 196.0;

  /// The inspector's dock: 44% of the window's height, within these.
  static const compactDockMin = 220.0, compactDockMax = 400.0;

  // ── Controls (Spectrum size S) ─────────────────────────────────────────────────────────────
  static const control = 24.0;
  static const icon = 18.0;
  static const radius = 7.0;
  static const segmentedHeight = 28.0;
  static const numberWidth = 60.0;

  // ── Inspector ──────────────────────────────────────────────────────────────────────────────
  static const headingPadding = EdgeInsets.fromLTRB(12, 8, 12, 0);
  static const tabsPadding = EdgeInsets.fromLTRB(12, 8, 12, 4);
  static const inspectorPadding = EdgeInsets.fromLTRB(12, 0, 12, 12);
  static const sectionPadding = EdgeInsets.symmetric(vertical: 2);
  static const sectionTitleHeight = 28.0;
  static const sectionBodyPadding = EdgeInsets.fromLTRB(8, 4, 8, 12);
  static const controlGap = 12.0;

  /// An adjustment: its name, then the track between its glyphs with the value at the end.
  static const labelGap = 3.0;
  static const endGlyph = 16.0;
  static const trackGap = 6.0;
  static const knob = 16.0;

  static const formatTileMin = 64.0;
  static const formatGap = 6.0;

  static const gradePadHeight = 136.0;
  static const gradePadRadius = 18.0;
  static const gradeGap = 6.0;

  // ── Film library ───────────────────────────────────────────────────────────────────────────
  static const libraryHeadingHeight = 32.0;
  static const libraryHeadingPadding = EdgeInsets.symmetric(horizontal: 12);
  static const searchPadding = EdgeInsets.fromLTRB(8, 4, 8, 6);
  static const stockListPadding = EdgeInsets.fromLTRB(6, 0, 6, 8);
  static const stockListCollapsedPadding = EdgeInsets.symmetric(vertical: 6, horizontal: 5);
  static const stockRowPadding = EdgeInsets.symmetric(horizontal: 6, vertical: 4);
  static const stockRowMinHeight = 40.0;
  static const stockRowGap = 1.0;
  static const normalRowGap = 6.0;
  static const stockThumb = Size(42, 32);
  static const stockThumbCollapsed = Size(40, 40);

  // ── Video controls (styles/video.css) ─────────────────────────────────────────────────────
  static const videoPadding = EdgeInsets.fromLTRB(18, 10, 18, 6);
  static const videoPaddingCompact = EdgeInsets.fromLTRB(12, 8, 12, 4);
  static const videoButton = 28.0;
  static const videoIcon = 20.0;
  static const videoPlayButton = 34.0;
  static const videoSeekHeight = 20.0;
  static const videoSettingsWidth = 310.0;

  // ── Viewer ─────────────────────────────────────────────────────────────────────────────────
  static const stripPadding = EdgeInsets.fromLTRB(10, 4, 10, 6);
  static const stripItem = Size(60, 44);
  static const histogramRect = Rect.fromLTWH(10, 10, 360, 232);
}
