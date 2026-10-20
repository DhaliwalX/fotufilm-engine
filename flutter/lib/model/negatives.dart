// Scanned negatives in the editor: importing scans and trichromatic exposures, a negative's
// reading, clear-film sampling, its roll and View › Show Negative. The rules are in
// negative_document.dart; the host's side is Sources/FotufilmHost/HostService+NegativeScan.swift.
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../engine/engine.dart';
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

  Future<void> openNegatives(List<PhotoFile> scans, {String? scanLight}) =>
      editor.openFiles(scans, negative: true, scanLight: scanLight);

  /// A new negative's edit: a new photograph's (`base`), on the film its base looks like, read
  /// against an estimated base.
  Json startingEdit(Json base, Json? scan, String? scanLight) => {
        ...base,
        'stock': negativeStartingStock(scan, editor.stocks, base['stock'] as String?),
        'negative': newNegative(scanLight ?? 'white'),
      };

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

  /// Crosstalk Correction while its slider moves.
  void setCrosstalk(double value) {
    final current = negative;
    if (current == null) return;
    editor.patch({'negative': {...current, 'crosstalk': value}}, group: 'negative-crosstalk');
  }

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

  /// Whether a click on the photograph picks the clear film.
  bool sampling = false;

  void setSampling(bool on) {
    if (sampling == on) return;
    sampling = on;
    editor.notify();
  }

  /// Samples clear film where `point` (0–1 across the shown picture) falls, and reads the scan
  /// against it.
  Future<void> sampleFilmBase(Offset point) async {
    final doc = _doc, engine = _engine;
    if (doc == null || engine == null || !sampling) return;
    if (point.dx < 0 || point.dx > 1 || point.dy < 0 || point.dy > 1) return;
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
          'negativeSampleFilmBase', {'render': request, 'point': [point.dx, point.dy]});
      final border = [for (final v in answer.value as List) (v as num).toDouble()];
      // The photograph or its edit moved on while the engine looked.
      if (!sampling || editor.active != doc || !identical(doc.edit, edit)) return;
      sampling = false;
      read({'border': border});
    } catch (e) {
      if (editor.active == doc) {
        editor
          ..error = '$e'
          ..notify();
      }
    }
  }

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

  /// Develops each frame small for its densest end, and keeps the roll's colour with every
  /// frame's edit: the shown one as an undoable change, the others in their histories.
  Future<void> measureRoll() async {
    final docs = rollFrames;
    if (docs.length < 2 || measuring != null) return;
    _cancelMeasure = false;
    measuring = RollProgress(0, docs.length);
    editor.notify();
    try {
      final ends = <List?>[];
      String? failure;
      for (final (index, doc) in docs.indexed) {
        if (_cancelMeasure) return;
        if (doc.edit['negative'] != null) {
          try {
            ends.add(await _denseEnd(doc));
          } catch (e) {
            failure ??= '${doc.name}: $e';
            ends.add(null);
          }
        }
        measuring = RollProgress(index + 1, docs.length);
        editor.notify();
      }
      if (_cancelMeasure) return;
      final roll = rollBalance(ends);
      if (roll == null) {
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

  /// A frame's densest end, from a small develop of it (`negativeMeasure`).
  Future<List?> _denseEnd(PhotoDocument doc) async {
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
        return (answer.json['negativeMeasure'] as Map?)?['denseEnd'] as List?;
      } on FotufilmCancelled {
        if (attempt >= 4 || _cancelMeasure) rethrow;
      }
    }
  }

  /// Sets the roll's colour, or none, on every frame of `docs`.
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
