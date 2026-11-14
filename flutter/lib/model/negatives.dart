// Scanned negatives in the editor: importing scans and trichromatic exposures, a negative's
// reading, clear-film sampling, its roll and View › Show Negative. The rules are in
// negative_document.dart; the host's side is Sources/FotufilmHost/HostService+NegativeScan.swift.
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../engine/engine.dart';
import 'crop_geometry.dart';
import 'editor.dart';
import 'edit.dart';
import 'file_types.dart';
import 'negative_document.dart';

export 'negative_document.dart';

/// Scans of negatives: unadjusted TIFFs and camera RAW, and the common still formats
/// (media-types.js `NEGATIVE_ACCEPT`).
const negativeExtensions = [
  'tif', 'tiff', 'png', 'jpg', 'jpeg', 'heic', //
  'dng', 'cr2', 'cr3', 'crw', 'nef', 'nrw', 'arw', 'srf', 'sr2', 'raf', 'orf', 'ori', 'rw2',
  'raw', 'rwl', 'pef', 'ptx', 'srw', '3fr', 'fff', 'iiq', 'kdc', 'dcr', 'mrw', 'mos', 'erf',
  'mef', 'mdc', 'x3f',
];

/// How far through Measure Roll is.
class RollProgress {
  const RollProgress(this.done, this.total);
  final int done, total;
}

class NegativeScans {
  NegativeScans(this.editor) {
    editor.renderOptionSources.add(_viewOptions);
    editor.renderOptionSources.add(_areaOptions);
    editor.addListener(_settlePanel);
  }

  final EditorModel editor;

  EngineConnection? get _engine => editor.engine;
  PhotoDocument? get _doc => editor.active;
  Json? get negative => editor.active == null ? null : editor.edit['negative'] as Json?;

  // ── Panels (negative-document.js documentPanels) ────────────────────────────────────────

  /// The inspector's tabs for the shown photograph, from the editor's.
  List<Panel> tabs(List<Panel> tabs) => [
        for (final id in documentPanelIds(_doc?.edit, [for (final p in tabs) p.id]))
          Panel.values.firstWhere((p) => p.id == id),
      ];

  /// A panel the shown photograph does not offer gives way to its Film panel.
  void _settlePanel() {
    // The picture area is picked on the shown negative, outside the crop tool.
    if (selectingArea && (negative == null || editor.crop.showing || editor.active != _areaDoc)) {
      selectingArea = false;
      _areaDoc = null;
    }
    final panel = editor.panel;
    if (offersPanel(_doc?.edit, panel.id)) return;
    editor.panel = Panel.film;
    if (panel.isTool) editor.renderer?.schedule();
    editor.notify();
  }

  // ── Importing ───────────────────────────────────────────────────────────────────────────

  /// Whether the engine reads scans (and trichromatic exposures, which it finds by path).
  bool get canImport => editor.ready && !editor.exporting;
  bool get canMerge => canImport && _engine?.opensPaths == true;

  /// Import Scanned Negative…: scans chosen in the open panel, each opened as a negative.
  Future<void> chooseNegatives() async {
    if (!canImport) return;
    final chosen = await chooseFiles([fileType('Scanned negatives', negativeExtensions)],
        android: const ['image/*']);
    await openNegatives([
      for (final f in chosen)
        PhotoFile(f.name, path: kIsWeb ? null : f.path, read: f.readAsBytes),
    ]);
  }

  Future<void> openNegatives(List<PhotoFile> scans, {String? scanLight}) async {
    await editor.openFiles(scans, negative: true, scanLight: scanLight);
    await _measureOpenedRoll();
  }

  /// Scans opened together are a roll: where the shown frame's roll has frames not yet measured
  /// with it, the roll is measured as they open, so each is balanced on what the roll's frames
  /// share and not on its own picture. A roll with a frame saved with an earlier reading is left
  /// to Measure Roll, which would change how that frame prints.
  Future<void> _measureOpenedRoll() async {
    final edits = [for (final doc in rollFrames) doc.edit['negative'] as Json?];
    if (edits.length < 2 || measuring != null) return;
    if (edits.any((n) => !readsModel(n)) || edits.every((n) => n?['roll'] != null)) return;
    await measureRoll(quiet: true);
  }

  /// A new negative's edit: a new photograph's (`base`), on the film its base looks like, read
  /// against an estimated base with the reading its scan opens with.
  Json startingEdit(Json base, Json? scan, String? scanLight) {
    final stock = negativeStartingStock(scan, editor.stocks, base['stock'] as String?);
    return {
      ...base,
      'stock': stock,
      'medium': mediumOnFilm(base, editor.stockById(stock)),
      'negative': newNegative(scanLight ?? 'white', (scan?['reading'] as num?)?.toInt() ?? 1,
          measuredCamera(scan)),
    };
  }

  /// Import Trichromatic Scan…: each frame's exposures under red, green and blue light, merged
  /// into scans beside the red ones.
  Future<void> chooseExposures() async {
    if (!canMerge) return;
    final chosen = await chooseFiles([fileType('Exposures', negativeExtensions)],
        confirmButtonText: 'Merge', android: const ['image/*']);
    if (chosen.isNotEmpty) await mergeExposures([for (final f in chosen) f.path]);
  }

  /// Merges exposures (`mergeTrichromatic`), opens the scans as negatives read with the LEDs'
  /// narrow channels, and says what was left out.
  Future<void> mergeExposures(List<String> paths) async {
    final engine = _engine;
    if (engine == null || paths.isEmpty) return;
    editor
      ..status = 'Merging exposures'
      ..notify();
    Json merged;
    try {
      merged = (await engine.call('mergeTrichromatic', {'paths': paths})).json;
    } catch (e) {
      editor
        ..status = null
        ..error = e is FotufilmCancelled ? null : 'The exposures could not be merged. $e'
        ..notify();
      return;
    }
    editor.status = null;
    final scans = ((merged['scans'] as List?) ?? const []).cast<Map>();
    if (scans.isNotEmpty) {
      await openNegatives([
        for (final s in scans) PhotoFile(s['name'] as String, path: s['path'] as String),
      ], scanLight: 'rgb');
    }
    final left = trichromaticNotes(merged);
    if (left.isNotEmpty) editor.error = left;
    editor.notify();
  }

  // ── The reading ─────────────────────────────────────────────────────────────────────────

  /// Changes how the scan is read, as one step.
  void read(Json change) {
    final current = negative;
    if (current == null) return;
    editor.change({'negative': {...current, ...change}});
  }

  /// Colour Separation (an earlier reading's Crosstalk Correction) while its slider moves.
  void setCrosstalk(double value) {
    final current = negative;
    if (current == null) return;
    editor.patch({'negative': {...current, 'crosstalk': value}}, group: 'negative-crosstalk');
  }

  /// Flare while its slider moves: the scan's stray light as a share of the frame's light.
  void setFlare(double value) {
    final current = negative;
    if (current == null) return;
    editor.patch({'negative': {...current, 'flare': value}}, group: 'negative-flare');
  }

  /// Density Strength while its slider moves: what every density over the clear film is
  /// multiplied by before the film is read. One, the scan as it measures, is kept as none.
  void setDensity(double value) {
    final current = negative;
    if (current == null) return;
    editor.patch({'negative': {...current, 'density': value == 1 ? null : value}},
        group: 'negative-density');
  }

  /// Whether the shown negative is read through its scan's light and camera (`readsModel`).
  bool get readsCurrent => readsModel(negative);

  /// The reading a negative opened now is made with, as the shown scan's descriptor says it.
  int? get currentReading => (_doc?.negativeScan?['reading'] as num?)?.toInt();

  /// Whether Update Reading has anything to do: the edit was saved with an earlier reading than
  /// the engine's.
  bool get canUpdateReading {
    final current = currentReading;
    return negative != null && current != null && ((negative!['reading'] as num?) ?? 1) < current;
  }

  /// Update Reading: the edit moved to the engine's current reading, as one step.
  void updateReading() {
    final current = negative, reading = currentReading;
    if (current == null || reading == null || !canUpdateReading) return;
    editor.change({
      'negative': updatedReading(current, reading, separates: measuredCamera(_doc?.negativeScan)),
    });
  }

  /// The camera the scan is read as taken with while the edit leaves that to its file: its
  /// name, null for the generic camera.
  String? get scannedWithName => (_doc?.negativeScan?['camera'] as Map?)?['name'] as String?;

  /// The films the scan's base looks like that are installed, up to three.
  List<Map> get suggestions {
    final installed = {
      for (final s in editor.stocks)
        if (readsNegative(s)) s['id'],
    };
    return [
      for (final s in ((_doc?.negativeScan?['suggestions'] as List?) ?? const []).cast<Map>())
        if (installed.contains(((s['films'] as List).first as Map)['id'])) s,
    ].take(3).toList();
  }

  // ── Clear film ──────────────────────────────────────────────────────────────────────────

  /// What the pointer picks on the photograph for the reading: with a click, the clear film it
  /// is measured against ('border') or something neutral its frame is balanced on ('neutral');
  /// with a rectangle drawn over some of it, the clearest film in the rectangle
  /// ('borderArea'); or nothing.
  String? picking;

  /// Whether a click on the photograph picks something for the reading.
  bool get sampling => picking != null;

  void setPicking(String? what) {
    if (picking == what) return;
    // One tool has the photograph at a time.
    if (what != null && selectingArea) {
      selectingArea = false;
      _areaDoc = null;
      editor.renderer?.schedule();
    }
    picking = what;
    editor.notify();
  }

  /// Pick Clear Film.
  void setSampling(bool on) => setPicking(on ? 'border' : null);

  /// Whether the clear film is picked by drawing a rectangle over it (Pick Clear Film Area).
  bool get pickingArea => picking == 'borderArea';

  /// Samples the scan where `point` (0–1 across the shown picture) falls, and keeps it with the
  /// reading as what is being picked: the clear film, or the frame's neutral.
  Future<void> sample(Offset point) async {
    if (pickingArea) return;
    if (point.dx < 0 || point.dx > 1 || point.dy < 0 || point.dy > 1) return;
    await _sample({'point': [point.dx, point.dy]});
  }

  /// Pick Clear Film Area: the clearest film in `area`, a rectangle drawn on the shown picture
  /// (0–1 across it), kept as the clear film the scan is measured against. A rectangle over a
  /// rebate or the gap between frames need not keep the picture, edge print or dust out; a
  /// sprocket hole or the bare light past the film is clearer than film and must stay outside.
  Future<void> sampleArea(Rect area) async {
    if (!pickingArea || area.width <= 0 || area.height <= 0) return;
    final within = area.intersect(const Rect.fromLTWH(0, 0, 1, 1));
    if (within.width <= 0 || within.height <= 0) return;
    await _sample({'area': [within.left, within.top, within.right, within.bottom]});
  }

  Future<void> _sample(Json where) async {
    final doc = _doc, engine = _engine, what = picking;
    if (doc == null || engine == null || what == null) return;
    final edit = doc.edit;
    final preview = doc.preview;
    final edge = preview != null
        ? (preview.width > preview.height ? preview.width : preview.height)
        : (doc.previewEdge > 0 ? doc.previewEdge : 1600);
    // The shown develop's request, as the scene it samples.
    final request = {
      ...renderRequest(
        catalogue: editor.catalogue,
        handle: doc.handle,
        edit: edit,
        stock: editor.stockById(edit['stock'] as String?),
        maxEdge: edge,
      ),
      ...editor.renderOptions(doc),
      'original': true,
    };
    try {
      final answer = await engine.call(
          what == 'neutral' ? 'negativeSampleNeutral' : 'negativeSampleFilmBase',
          {'render': request, ...where});
      final sampled = [for (final v in answer.value as List) (v as num).toDouble()];
      // The photograph or its edit moved on while the engine looked.
      if (picking != what || editor.active != doc || !identical(doc.edit, edit)) return;
      picking = null;
      // A neutral picked on a frame is the frame's own: a frame balanced on its roll is
      // balanced on itself from here, still with its roll's contrast.
      read({
        what == 'borderArea' ? 'border' : what: sampled,
        if (what == 'neutral' && balanceOf(negative) == 'roll') 'balance': 'frame',
      });
    } catch (e) {
      if (editor.active == doc) {
        editor
          ..error = '$e'
          ..notify();
      }
    }
  }

  // ── Picture area ────────────────────────────────────────────────────────────────────────

  /// Whether the picture area is being picked: the viewer shows the whole frame with the
  /// area's four corners over it, each dragged on its own, as the crop tool shows a crop.
  bool selectingArea = false;
  PhotoDocument? _areaDoc;

  /// The picture area picked on the shown negative, where it is one its frame can be read on
  /// (`WebNativeEdit.Negative.pictureArea`): four corners of the oriented frame, top left
  /// first, turning the same way round.
  List<Offset>? get pickedArea {
    final area = negative?['area'];
    if (area is! List || area.length != 4) return null;
    final points = cropPoints(area);
    return validCrop(points) ? points : null;
  }

  /// The area's corners as the overlay shows them: the picked ones, else where picking starts,
  /// the crop where the frame is cropped and the frame less a tenth at each edge where it is
  /// not, which is what a frame without an area measures.
  List<Offset> get areaPoints {
    final picked = pickedArea;
    if (picked != null) return picked;
    final crop = cropPoints(editor.edit['crop']);
    return isFullCrop(crop) || !validCrop(crop) ? rectangleCrop(.1, .1, .9, .9) : crop;
  }

  /// Select Picture Area, and Done: leaving keeps the corners as they stand.
  void toggleArea() {
    if (negative == null) return;
    if (selectingArea) return finishArea();
    if (editor.crop.showing) editor.crop.leave();
    picking = null;
    selectingArea = true;
    _areaDoc = editor.active;
    if (editor.view.zoom != null) editor.setZoom(null);
    editor.notify();
    editor.renderer?.schedule();
  }

  /// Done, and Return: the corners on show are the picture area.
  void finishArea() {
    if (!selectingArea) return;
    if (negative != null && pickedArea == null) setArea(areaPoints);
    leaveArea();
  }

  /// Escape: the tool closes with the area as it was last set.
  void leaveArea() {
    if (!selectingArea) return;
    selectingArea = false;
    _areaDoc = null;
    editor.notify();
    editor.renderer?.schedule();
  }

  /// The corners the overlay was let go at, as one step.
  void setArea(List<Offset> corners) {
    if (validCrop(corners)) read({'area': cropJson(corners)});
  }

  /// Clear Picture Area: the frame measures the middle of its crop again.
  void clearArea() {
    if (negative?['area'] != null) read({'area': null});
  }

  /// Use on Every Frame of the Roll: the shown frame's picture area on each frame of its roll
  /// that is turned as it is, a holder showing every frame of a roll in one place. The shown
  /// frame is left as it is; the others take it in their histories.
  void areaOnRoll() {
    final area = pickedArea, shown = editor.active;
    if (area == null || shown == null) return;
    bool turnedAlike(Json a, Json b) =>
        ((a['rotation'] as num?) ?? 0) == ((b['rotation'] as num?) ?? 0) &&
        (a['flip'] == true) == (b['flip'] == true);
    for (final doc in rollFrames) {
      final before = doc.edit['negative'] as Json?;
      if (doc == shown || before == null || !turnedAlike(doc.edit, shown.edit)) continue;
      final h = doc.history;
      h.past.add(h.present);
      h.future.clear();
      h.present = copyEdit(h.present)..['negative'] = {...before, 'area': cropJson(area)};
      h.group = null;
    }
    editor.notify();
  }

  /// The develops of the shown picture while its area is picked: the whole frame, cropless, as
  /// the crop tool shows it, so the corners lie where the scan shows them.
  Json _areaOptions(PhotoDocument doc) => !selectingArea || doc != _areaDoc
      ? const <String, dynamic>{}
      : {
          'cropMode': true,
          'edit': copyEdit(doc.edit)
            ..['crop'] = fullCrop()
            ..['ratio'] = 'free',
        };

  // ── Light frames ────────────────────────────────────────────────────────────────────────

  List<Json>? _lightFrames;
  bool _loadingLights = false;

  /// Whether the host keeps light frames: one with a file system does, a browser does not.
  bool get keepsLightFrames => _engine?.opensPaths == true;

  /// The light frames the host keeps: as the scan opened with them, then as they change.
  List<Json> get lightFrames {
    if (_lightFrames == null && !_loadingLights) _loadLightFrames();
    return _lightFrames ??
        ((_doc?.negativeScan?['lightFrames'] as List?) ?? const []).cast<Json>();
  }

  Future<void> _loadLightFrames() async {
    final engine = _engine;
    if (engine == null || !keepsLightFrames) return;
    _loadingLights = true;
    try {
      final answer = await engine.call('negativeLightFrames');
      _lightFrames = [for (final f in (answer.value as List?) ?? const []) (f as Map).cast()];
      editor.notify();
    } catch (_) {
      // The list the scan opened with stands.
    } finally {
      _loadingLights = false;
    }
  }

  /// Add Light Frame…: a photograph of the bare light source, which evens out this scan's light.
  Future<void> chooseLightFrame() async {
    final all = await chooseFiles([fileType('Light frames', negativeExtensions)],
        android: const ['image/*']);
    if (all.isEmpty) return;
    final chosen = all.first;
    await addLightFrame(PhotoFile(chosen.name,
        path: kIsWeb ? null : chosen.path, read: chosen.readAsBytes));
  }

  Future<void> addLightFrame(PhotoFile file) async {
    final engine = _engine;
    if (engine == null || negative == null) return;
    try {
      final answer = engine.opensPaths && file.path != null
          ? await engine.call('negativeAddLightFrame', {'path': file.path})
          : await engine.call(
              'negativeAddLightFrame', {'name': file.name}, await file.read!());
      await _loadLightFrames();
      read({'lightFrame': answer.json['id']});
    } catch (e) {
      editor
        ..error = '$e'
        ..notify();
    }
  }

  Future<void> removeLightFrame() async {
    final engine = _engine, id = negative?['lightFrame'];
    if (engine == null || id == null) return;
    await engine.call('negativeRemoveLightFrame', {'id': id});
    await _loadLightFrames();
    read({'lightFrame': null});
  }

  // ── The roll ────────────────────────────────────────────────────────────────────────────

  /// The strip's negatives on the shown frame's roll (its folder), the shown one among them.
  List<PhotoDocument> get rollFrames {
    final docs = editor.documents;
    if (negative == null) return const [];
    return [
      for (final i in rollIndices([for (final d in docs) d.path],
          [for (final d in docs) d.negativeScan != null], editor.activeIndex))
        docs[i],
    ];
  }

  /// Measure Roll's progress, null while it is not measuring.
  RollProgress? measuring;
  bool _cancelMeasure = false;

  /// The edge each frame develops at to be measured.
  static const _measureEdge = 480;

  /// Develops each frame small for what it measures, and keeps what the roll's frames share
  /// with every frame's edit: the shown one as an undoable change, the others in their
  /// histories. `quiet` says nothing of a roll that could not be measured, which leaves each
  /// frame on its own.
  Future<void> measureRoll({bool quiet = false}) async {
    final docs = rollFrames;
    if (docs.length < 2 || measuring != null) return;
    _cancelMeasure = false;
    measuring = RollProgress(0, docs.length);
    editor.notify();
    try {
      final measures = <Map?>[];
      String? failure;
      for (final (index, doc) in docs.indexed) {
        if (_cancelMeasure) return;
        if (doc.edit['negative'] != null) {
          try {
            measures.add(await _measure(doc));
          } catch (e) {
            failure ??= '${doc.name}: $e';
            measures.add(null);
          }
        }
        measuring = RollProgress(index + 1, docs.length);
        editor.notify();
      }
      if (_cancelMeasure) return;
      final roll = rollBalance(measures);
      if (roll == null) {
        if (quiet) return;
        // A frame that could not be developed says why; otherwise the frames were too thin.
        editor.error = failure != null
            ? 'The roll could not be measured. $failure'
            : 'Fewer than two frames of this roll show highlights to balance on. Crop away the '
                'holder, or measure a roll with more frames.';
        return;
      }
      _applyRoll(docs, roll);
    } finally {
      measuring = null;
      editor.notify();
    }
  }

  void cancelMeasure() => _cancelMeasure = true;

  /// What a frame measures for its roll, from a small develop of it (`negativeMeasure`): its
  /// densest end, its average, its clear film and the rises across its tonal steps.
  Future<Map?> _measure(PhotoDocument doc) async {
    final edit = doc.edit;
    final request = {
      ...renderRequest(
        catalogue: editor.catalogue,
        handle: doc.handle,
        edit: thumbnailEdit(edit, edit['stock'] as String?),
        stock: editor.stockById(edit['stock'] as String?),
        maxEdge: _measureEdge,
      ),
      'original': false,
    };
    // The renderer cancels the develop in progress for a newer edit; that is not this frame's.
    for (var attempt = 0;; attempt++) {
      try {
        final answer = await _engine!.call('render', request);
        return answer.json['negativeMeasure'] as Map?;
      } on FotufilmCancelled {
        if (attempt >= 4 || _cancelMeasure) rethrow;
      }
    }
  }

  /// Sets what the roll measured, or nothing, on every frame of `docs`.
  void _applyRoll(List<PhotoDocument> docs, Json? roll) {
    for (final doc in docs) {
      final before = doc.edit['negative'] as Json?;
      if (before == null) continue;
      final after = {...before, 'roll': roll};
      if (doc == editor.active) {
        editor.change({'negative': after});
        continue;
      }
      final h = doc.history;
      h.past.add(h.present);
      h.future.clear();
      h.present = copyEdit(h.present)..['negative'] = after;
      h.group = null;
    }
    editor.notify();
  }

  /// Balance Every Frame Alone: every frame of the roll back on its own balance.
  void clearRoll() {
    final docs = rollFrames;
    if (docs.isNotEmpty) _applyRoll(docs, null);
  }

  /// Clear Picked Neutral: the frame back on what it is balanced on without one, its roll once
  /// measured.
  void clearNeutral() => read({'neutral': null, 'balance': null});

  /// Balance This Frame Alone.
  void unrollFrame() {
    if (negative?['roll'] != null) read({'roll': null});
  }

  // ── Show Negative ───────────────────────────────────────────────────────────────────────

  /// Whether the canvas develops the film's negative in place of the edit's output: a way of
  /// looking, not part of the edit.
  bool showNegative = false;

  bool get canShowNegativeNow =>
      _doc != null && canShowNegative(editor.edit, editor.selectedStock);

  void toggleShowNegative() {
    showNegative = !showNegative;
    editor.notify();
    editor.renderer?.schedule();
  }

  /// The shown picture's edit, on the negative medium while the negative is shown.
  Json _viewOptions(PhotoDocument doc) {
    if (!showNegative) return const {};
    final stock = editor.stockById(doc.edit['stock'] as String?);
    if (!canShowNegative(doc.edit, stock)) return const {};
    final viewed = negativeViewEdit(doc.edit, stock, true);
    final request = renderRequest(
        catalogue: editor.catalogue, handle: doc.handle, edit: viewed, stock: stock, maxEdge: null);
    return {'edit': viewed, 'profileRequest': request['profileRequest']};
  }
}
