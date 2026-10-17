// The editor's state and actions: the engine and its films, the open photographs and their edit
// histories, and the workspace (panels, zoom, histogram). It follows the React editor's model
// (web/src/editor/useEditorModel.js); what the engine develops and when is the Renderer's
// business (renderer.dart).
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../engine/presenter.dart';
import 'catalogue.dart';
import 'document.dart';
import 'edit.dart';
import 'film_types.dart';
import 'histogram.dart';
import 'renderer.dart';
import 'view.dart';

export 'catalogue.dart' show Json;
export 'document.dart';
export 'film_types.dart';
export 'view.dart';

enum Panel { film, light, develop, print }

extension PanelInfo on Panel {
  String get id => const ['film', 'light', 'develop', 'print'][index];
  String get title => const ['Film', 'Expose', 'Develop', 'Print'][index];
  String get icon => const ['film', 'expose', 'develop', 'print'][index];
}

class EditorModel extends ChangeNotifier implements RenderHost {
  EditorModel(this.catalogue);

  final Catalogue catalogue;
  EngineConnection? engine;
  NativePresenter? presenter;
  Renderer? renderer;
  String? startupError;

  bool get ready => renderer != null && stocks.isNotEmpty;

  /// Whether the engine has work in hand or waiting.
  bool get busy => (renderer?.busy ?? false) || status != null || _viewSettle != null;

  // ── Films ─────────────────────────────────────────────────────────────────────────────────

  /// The engine's films (`prepare`'s catalogue), in the order the library lists them.
  @override
  List<Json> stocks = [];
  final Map<String, Json> _stockById = {};

  @override
  Json? stockById(String? id) => id == null ? null : _stockById[id];

  /// The film types the library offers, and the one it shows.
  List<FilmType> filmTypes = const [FilmType.all];
  FilmType filmType = FilmType.all;

  // ── Photographs ───────────────────────────────────────────────────────────────────────────

  final List<PhotoDocument> documents = [];
  int activeIndex = -1;

  @override
  PhotoDocument? get active =>
      activeIndex >= 0 && activeIndex < documents.length ? documents[activeIndex] : null;
  Json get edit => active?.edit ?? _emptyEdit;
  late final Json _emptyEdit = defaultEdit(catalogue);
  Json? get selectedStock => stockById(edit['stock'] as String?);

  ui.Size get photoSize => active == null
      ? ui.Size.zero
      : ui.Size(active!.width.toDouble(), active!.height.toDouble());

  // ── Workspace ─────────────────────────────────────────────────────────────────────────────

  Panel panel = Panel.film;
  bool filmOpen = true;
  bool inspectorOpen = true;
  @override
  bool histogramOpen = false;

  /// Whether the format tiles show a quarter of the frame, where grain and halation tell.
  @override
  bool formatDetail = true;
  bool presetsTab = false;
  bool autoAdjust = false;
  bool comparing = false;
  bool exporting = false;
  String search = '';
  String? status;
  String? error;
  HistogramData? histogram;

  @override
  final ViewState view = ViewState();

  // ── RenderHost ────────────────────────────────────────────────────────────────────────────

  @override
  void rendered() => notifyListeners();

  @override
  void renderFailed(String message) {
    // Without a film there may be nothing to develop; that is not worth a banner.
    final doc = active;
    if (doc == null || doc.edit['stock'] != null || doc.preview == null) error = message;
    notifyListeners();
  }

  @override
  void measured(HistogramData? data) {
    histogram = data;
    notifyListeners();
  }

  // ── Start-up ──────────────────────────────────────────────────────────────────────────────

  Future<void> start() async {
    try {
      final engine = await connectEngine();
      final prepared = await engine.call('prepare');
      final ids = ((prepared.json['stocks'] as List?) ?? const []).cast<String>().toSet();
      stocks = [
        for (final entry in ((prepared.json['catalogue'] as List?) ?? const []).cast<Json>())
          if (ids.contains(entry['id'])) entry,
      ]..sort((a, b) => _sortName(a).compareTo(_sortName(b)));
      for (final s in stocks) {
        _stockById[s['id'] as String] = s;
      }
      filmTypes = FilmType.offered(stocks);
      final address = engine.address;
      if (address != null) presenter = await NativePresenter.attach(address);
      this.engine = engine;
      renderer = Renderer(engine: engine, catalogue: catalogue, host: this, presenter: presenter);
    } catch (e) {
      startupError = '$e';
    }
    notifyListeners();
  }

  /// Films by name, ignoring a maker's prefix so Aerochrome sits with the A's.
  static String _sortName(Json stock) => (stock['name'] as String)
      .replaceFirst(RegExp(r'^(Kodak|Fujifilm|Fuji|Ilford) '), '')
      .toLowerCase();

  // ── Opening and closing ───────────────────────────────────────────────────────────────────

  /// Opens photographs the system named by path (the Finder, the command line, the driver).
  Future<void> openPaths(List<String> paths) =>
      openFiles([for (final path in paths) PhotoFile(path.split('/').last, path: path)]);

  /// Opens photographs: by path where the engine reads files itself, otherwise by their bytes.
  Future<void> openFiles(List<PhotoFile> files) async {
    final engine = this.engine;
    if (engine == null || files.isEmpty) return;
    // A new photograph starts on the film the shown one is on, as the web editor's do.
    final stock = edit['stock'] as String?;
    var opened = 0;
    for (final file in files) {
      final key = file.path ?? file.name;
      final existing = documents.indexWhere((d) => d.path == key);
      if (existing >= 0) {
        _activate(existing);
        continue;
      }
      status = 'Opening ${file.name}…';
      notifyListeners();
      try {
        final answer = engine.opensPaths && file.path != null
            ? await engine.call('importPath', {'path': file.path, 'negative': false})
            : await engine.call(
                'importFile', {'name': file.name, 'negative': false}, await file.read!());
        final json = answer.json;
        final doc = PhotoDocument(
          path: key,
          handle: (json['handle'] as num).toInt(),
          width: (json['naturalWidth'] as num).toInt(),
          height: (json['naturalHeight'] as num).toInt(),
          identity: json['identity'] as String?,
          raw: json['original'] != null,
          history: History(defaultEdit(catalogue, stock)),
        );
        final preview = answer.bytes('preview');
        if (preview != null) doc.importPicture = await decodePng(preview);
        documents.add(doc);
        _activate(documents.length - 1);
        opened++;
      } catch (e) {
        error = '${file.name} could not be opened. $e';
      }
    }
    status = null;
    if (opened > 0 && autoAdjust) await runAutoAdjust();
    notifyListeners();
  }

  void _activate(int index) {
    activeIndex = index;
    view
      ..zoom = null
      ..pan = ui.Offset.zero;
    comparing = false;
    histogram = null;
    notifyListeners();
    renderer?.schedule();
  }

  void selectDocument(int index) {
    if (index == activeIndex) return;
    endEdit();
    _activate(index);
  }

  Future<void> closeDocument(int index) async {
    final doc = documents.removeAt(index);
    if (index < activeIndex || activeIndex >= documents.length) activeIndex--;
    if (activeIndex < 0 && documents.isNotEmpty) activeIndex = 0;
    notifyListeners();
    await engine?.call('release', {'handle': doc.handle});
    renderer?.schedule();
  }

  // ── Editing (web/src/editor-state.js historyReducer) ─────────────────────────────────────

  bool get canUndo => active?.history.past.isNotEmpty ?? false;
  bool get canRedo => active?.history.future.isNotEmpty ?? false;
  bool get edited =>
      active != null && !sameEdit(edit, defaultEdit(catalogue, edit['stock'] as String?));

  /// Changes the edit. Changes under one `group` (a slider being dragged) make one step.
  void patch(Json changes, {String? group}) {
    final doc = active;
    if (doc == null) return;
    final h = doc.history;
    final next = copyEdit(h.present)..addAll(changes);
    if (sameEdit(next, h.present)) return;
    if (group == null || h.group != group) {
      h.past.add(h.present);
      h.future.clear();
    }
    h.present = next;
    h.group = group;
    notifyListeners();
    renderer?.schedule(interactive: group != null);
  }

  /// A change made in one step: a picker, a switch or a button.
  void change(Json changes) {
    endEdit();
    patch(changes);
  }

  /// Ends a grouped change (a slider let go), so the picture develops at full size.
  void endEdit() {
    final doc = active;
    if (doc == null || doc.history.group == null) return;
    doc.history.group = null;
    renderer?.schedule();
  }

  void setParam(String key, double value) =>
      patch({'params': {...(edit['params'] as Map), key: value}}, group: 'param-$key');

  /// Several adjustments moved together (the grade pad's two axes), as one step.
  void setParams(Map<String, double> values, String group) =>
      patch({'params': {...(edit['params'] as Map), ...values}}, group: group);

  void setProfile(String field, Object? value, {bool grouped = true}) {
    final profile = Map<String, dynamic>.from(edit['profile'] as Map);
    if (value == null) {
      profile.remove(field);
    } else {
      profile[field] = value;
    }
    // Reach sets the pair couplings, so explicit ones give way (profile-settings.js).
    if (field == 'couplerReach') {
      profile.remove('couplerRedGreen');
      profile.remove('couplerGreenBlue');
    }
    if (grouped) {
      patch({'profile': profile}, group: 'profile-$field');
    } else {
      change({'profile': profile});
    }
  }

  void chooseStock(String? id) {
    if (active == null) return;
    final stock = stockById(id);
    // A medium the next film has no print for falls back to its own default, as the web does.
    final media = ((stock?['media'] as List?) ?? const []).map((m) => (m as Map)['id']).toSet();
    final medium = edit['mediumFollowsFilm'] == true
        ? (stock?['filmMedium'])
        : (media.contains(edit['medium']) ? edit['medium'] : null);
    change({'stock': id, 'medium': medium});
  }

  void undo() => _step(back: true);
  void redo() => _step(back: false);

  void _step({required bool back}) {
    final h = active?.history;
    if (h == null || (back ? h.past : h.future).isEmpty) return;
    if (back) {
      h.future.insert(0, h.present);
      h.present = h.past.removeLast();
    } else {
      h.past.add(h.present);
      h.present = h.future.removeAt(0);
    }
    h.group = null;
    notifyListeners();
    renderer?.schedule();
  }

  void resetEdit() {
    if (active != null) change(defaultEdit(catalogue, edit['stock'] as String?));
  }

  void newGrainPattern() => change({'seed': math.Random().nextInt(0x7fffffff) + 1});

  Future<void> runAutoAdjust() async {
    final doc = active, engine = this.engine;
    if (doc == null || engine == null) return;
    try {
      final answer = await engine.call('autoAdjust', {'handle': doc.handle, 'edit': doc.edit});
      final params = Map<String, dynamic>.from(edit['params'] as Map);
      for (final key in const ['ev', 'highlights', 'shadows']) {
        final value = answer.json[key];
        if (value is num) params[key] = value.toDouble();
      }
      change({'params': params});
    } catch (e) {
      error = 'Auto adjust failed. $e';
      notifyListeners();
    }
  }

  // ── Workspace actions ─────────────────────────────────────────────────────────────────────

  void _set(VoidCallback update) {
    update();
    notifyListeners();
  }

  void setPanel(Panel next) => _set(() {
        panel = next;
        inspectorOpen = true;
      });
  void toggleFilm() => _set(() => filmOpen = !filmOpen);
  void toggleInspector() => _set(() => inspectorOpen = !inspectorOpen);
  void setPresetsTab(bool value) => _set(() => presetsTab = value);
  void setSearch(String value) => _set(() => search = value);
  void setFilmType(FilmType value) => _set(() => filmType = value);
  void dismissError() => _set(() => error = null);

  void setComparing(bool value) {
    if (comparing == value || active == null) return;
    _set(() => comparing = value);
  }

  void toggleHistogram() {
    _set(() => histogramOpen = !histogramOpen);
    if (histogramOpen) renderer?.schedule();
  }

  void toggleAutoAdjust() {
    _set(() => autoAdjust = !autoAdjust);
    if (autoAdjust) runAutoAdjust();
  }

  void setFormatDetail(bool value) {
    _set(() => formatDetail = value);
    renderer?.schedule();
  }

  // ── View ──────────────────────────────────────────────────────────────────────────────────

  double get scale => view.scale(photoSize);
  double get fitScale => view.fitScale(photoSize);
  bool get zoomed => view.zoom != null;

  /// The view moved: the picture follows at once, and develops for it once it stops moving,
  /// so a pinch or a window resize does not start a develop for every frame.
  Timer? _viewSettle;
  void _viewChanged() {
    notifyListeners();
    _viewSettle?.cancel();
    _viewSettle = Timer(const Duration(milliseconds: 120), () {
      _viewSettle = null;
      renderer?.schedule();
    });
  }

  void updateViewer(ui.Size size, double dpr) {
    if (size == view.viewer && dpr == view.devicePixelRatio) return;
    view
      ..viewer = size
      ..devicePixelRatio = dpr
      ..clampPan(photoSize);
    _viewChanged();
  }

  /// Magnifies to `value` around the viewer's centre, or fits the photograph when null.
  void setZoom(double? value) {
    if (value == null) {
      view
        ..zoom = null
        ..pan = ui.Offset.zero;
    } else {
      view.zoomAround(photoSize, value, view.viewer.center(ui.Offset.zero));
    }
    _viewChanged();
  }

  /// Magnifies to `value`, keeping the point under `focal` (viewer coordinates) still.
  void zoomAround(double value, ui.Offset focal) {
    view.zoomAround(photoSize, value, focal);
    _viewChanged();
  }

  void panBy(ui.Offset delta) {
    if (view.zoom == null) return;
    view
      ..pan += delta
      ..clampPan(photoSize);
    _viewChanged();
  }

  void zoomIn() => setZoom(
      ViewState.steps.firstWhere((s) => s > scale * 1.001, orElse: () => ViewState.maxZoom));

  void zoomOut() {
    final next = ViewState.steps.lastWhere((s) => s < scale * 0.999, orElse: () => fitScale);
    setZoom(next <= fitScale ? null : next);
  }

  // ── Export ────────────────────────────────────────────────────────────────────────────────

  Future<String> export({
    required String path,
    required String type,
    required double quality,
    required int? maxEdge,
    required String metadata,
  }) async {
    final doc = active, engine = this.engine;
    if (doc == null || engine == null) throw StateError('No photograph is open.');
    _set(() => exporting = true);
    try {
      final answer = await engine.call('export', {
        ...renderRequest(
          catalogue: catalogue,
          handle: doc.handle,
          edit: doc.edit,
          stock: stockById(doc.edit['stock'] as String?),
          maxEdge: maxEdge,
        ),
        'type': type,
        'quality': quality,
        'metadata': metadata,
        'hdr': false,
        'photoQuality': 'accurate',
        'filename': path.split('/').last,
        'path': path,
      });
      return answer.json['path'] as String? ?? path;
    } finally {
      _set(() => exporting = false);
    }
  }
}

/// A photograph to open: its name, and its path where there is a file system, or its bytes.
class PhotoFile {
  PhotoFile(this.name, {this.path, this.read});
  final String name;
  final String? path;
  final Future<Uint8List> Function()? read;
}
