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
import 'auto_adjust.dart';
import 'band_sets.dart';
import 'catalogue.dart';
import 'crop.dart';
import 'crop_geometry.dart';
import 'document.dart';
import 'edit.dart';
import 'edit_history.dart';
import 'export.dart';
import 'film_suggestion.dart';
import 'film_types.dart';
import 'histogram.dart';
import 'kept_edits.dart';
import 'lens.dart';
import 'negatives.dart';
import 'pipeline.dart';
import 'presets.dart';
import 'print_frame.dart';
import 'renderer.dart';
import 'selective.dart';
import 'settings.dart';
import 'strip_selection.dart';
import 'view.dart';

export 'catalogue.dart' show Json;
export 'document.dart';
export 'film_types.dart';
export 'settings.dart';
export 'view.dart';

/// The inspector's panels: the four tabs, the roll's tab for scanned negatives, and the canvas
/// tools the toolbar opens (editor-catalogue.js `inspectorPanels`, negative-document.js).
enum Panel {
  film('film', 'Film', 'film'),
  light('light', 'Expose', 'expose'),
  develop('develop', 'Develop', 'develop'),
  print('print', 'Print', 'print'),
  roll('roll', 'Roll', 'negative'),
  crop('crop', 'Crop', 'crop'),
  selective('selective', 'Selective', 'selective'),
  pipeline('pipeline', 'Pipeline', 'pipeline');

  const Panel(this.id, this.title, this.icon);
  final String id, title, icon;

  /// The inspector's tabs for every photograph.
  static const tabs = [film, light, develop, print];

  /// The canvas tools: they take the inspector over and change what the viewer shows.
  bool get isTool => this == crop || this == selective || this == pipeline;
}

class EditorModel extends ChangeNotifier implements RenderHost {
  EditorModel(this.catalogue, {AppSettings? settings})
      : settings = settings ?? AppSettings.memory() {
    // The features attach now: they add to the render options before anything develops, and
    // listen to edits before the first one.
    [crop, selective, pipeline, negatives, printFrame, keptEdits, auto];
  }

  /// The crop tool (crop.dart).
  late final crop = CropTool(this);

  final Catalogue catalogue;

  /// Export, Export All, Export Original and Copy Photo (export.dart).
  late final exporter = ExportTool(this);

  /// Preferences and remembered things, kept on this device.
  final AppSettings settings;

  // ── Features ──────────────────────────────────────────────────────────────────────────────
  late final history = EditHistory(this);
  late final strip = StripSelection(this);
  late final presets = Presets(this);
  late final keptEdits = KeptEdits(this);
  late final auto = AutoAdjustment(this);
  late final filmSuggestion = FilmSuggestion(this);
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

  /// The picture on show at full size: the cropped photograph, or the crop tool's whole frame.
  /// Until one is on show, the one asked for.
  ui.Size get photoSize => active == null
      ? ui.Size.zero
      : printFrame.framed(active!.shownSize ?? developedSize(active!, renderOptions(active!)));

  // ── Workspace ─────────────────────────────────────────────────────────────────────────────

  Panel panel = Panel.film;

  /// The inspector's tabs for the shown photograph (negative-document.js `documentPanels`).
  List<Panel> get inspectorTabs => negatives.tabs(Panel.tabs);
  bool filmOpen = true;
  bool inspectorOpen = true;
  @override
  bool histogramOpen = false;

  /// Whether the format tiles show a quarter of the frame, where grain and halation tell.
  @override
  bool formatDetail = true;
  bool presetsTab = false;
  bool get autoAdjust => auto.active;
  bool comparing = false;
  bool exporting = false;
  String search = '';
  String? status;
  String? error;
  HistogramData? histogram;

  @override
  final ViewState view = ViewState();

  /// The Expose panel's lens correction, and the Print panel's frame and receiver band sets.
  late final lens = LensCorrection(this);
  late final printFrame = PrintFrame(this);
  late final bandSets = BandSets(catalogue, settings);

  /// What the foreground develops ask the engine for beyond the edit (session.js
  /// `renderRequest`): the crop tool's uncropped frame, a pipeline stage, the selection's mask.
  /// Features add to it through [renderOptionSources].
  @override
  Json renderOptions(PhotoDocument doc) => {
        for (final source in renderOptionSources) ...source(doc),
      };
  final List<Json Function(PhotoDocument doc)> renderOptionSources = [];

  // ── Canvas tools ──────────────────────────────────────────────────────────────────────────

  late final selective = SelectiveTool(this)..addListener(notifyListeners);
  late final pipeline = PipelineTool(this)..addListener(notifyListeners);


  // ── Features ──────────────────────────────────────────────────────────────────────────────

  /// Scanned negatives: importing them, their reading, their roll and Show Negative.
  late final negatives = NegativeScans(this);

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

  /// The Presets tab's rows, while it is shown: each preset pasted onto the photograph.
  @override
  Map<String, Json> presetEdits(PhotoDocument doc) => {
        if (filmOpen && presetsTab)
          for (final preset in presets.visible)
            preset.id: ?presets.shownWith(preset, doc.edit),
      };

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
  /// `negative` opens them as scanned negatives, read as a film (negatives.dart).
  Future<void> openFiles(List<PhotoFile> files, {bool negative = false, String? scanLight}) async {
    final engine = this.engine;
    if (engine == null || files.isEmpty) return;
    // A new photograph starts on the film the shown one is on, as the web editor's do.
    final stock = edit['stock'] as String?;
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
            ? await engine.call('importPath', {'path': file.path, 'negative': negative})
            : await engine.call(
                'importFile', {'name': file.name, 'negative': negative}, await file.read!());
        final json = answer.json;
        // A photograph opened before starts from the edit it was left with.
        final start = keptEdits.startingEdit(json['identity'] as String?, stock);
        final doc = PhotoDocument(
          path: key,
          handle: (json['handle'] as num).toInt(),
          width: (json['naturalWidth'] as num).toInt(),
          height: (json['naturalHeight'] as num).toInt(),
          identity: json['identity'] as String?,
          raw: json['original'] != null,
          headroom: ((json['hdr'] as Map?)?['headroom'] as num?)?.toDouble() ?? 1,
          // A new scan starts as a negative; one opened before keeps the edit it was left with.
          history: History(negative && !start.saved
              ? negatives.startingEdit(start.edit, json['negative'] as Json?, scanLight)
              : start.edit),
        )..negativeScan = json['negative'] as Json?;
        keptEdits.opened(doc, saved: start.saved);
        filmSuggestion.opened(doc, saved: start.saved);
        final preview = answer.bytes('preview');
        if (preview != null) doc.importPicture = await decodePng(preview);
        documents.add(doc);
        _activate(documents.length - 1);
      } catch (e) {
        error = '${file.name} could not be opened. $e';
      }
    }
    status = null;
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

  /// Told of each change to a photograph's history, so features follow edits (kept edits, Auto
  /// Adjust).
  final List<void Function(EditChange change)> editListeners = [];

  /// A photograph's history changed (`kind`: edit, undo, redo, goTo or replace) from `before`:
  /// the picture follows and the features are told.
  void historyChanged(PhotoDocument doc, String kind, Json before, {bool restoring = false}) {
    notifyListeners();
    renderer?.schedule(interactive: doc.history.group != null);
    final change = EditChange(doc, kind, before, restoring: restoring);
    for (final listener in [...editListeners]) {
      listener(change);
    }
  }

  void showError(String message) => _set(() => error = message);

  /// Replaces the edit with a whole one (a paste, a preset, Load Edits), as one step.
  void restore(Json edit) {
    endEdit();
    error = null;
    patch(edit, restoring: true);
  }

  /// Changes the edit. Changes under one `group` (a slider being dragged) make one step.
  void patch(Json changes, {String? group, bool restoring = false}) {
    final doc = active;
    if (doc == null) return;
    final h = doc.history;
    final next = copyEdit(h.present)..addAll(changes);
    if (sameEdit(next, h.present)) return;
    if (group == null || h.group != group) {
      h.past.add(h.present);
      h.future.clear();
    }
    final before = h.present;
    h.present = next;
    h.group = group;
    historyChanged(doc, 'edit', before, restoring: restoring);
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
    final before = h.present;
    if (back) {
      h.future.insert(0, h.present);
      h.present = h.past.removeLast();
    } else {
      h.past.add(h.present);
      h.present = h.future.removeAt(0);
    }
    h.group = null;
    historyChanged(active!, back ? 'undo' : 'redo', before);
  }

  void resetEdit() {
    if (active != null) change(defaultEdit(catalogue, edit['stock'] as String?));
  }

  void newGrainPattern() => change({'seed': math.Random().nextInt(0x7fffffff) + 1});

  /// Auto Adjust's mode on or off (auto_adjust.dart).
  void toggleAutoAdjust() => auto.toggle();

  // ── Workspace actions ─────────────────────────────────────────────────────────────────────

  void _set(VoidCallback update) {
    update();
    notifyListeners();
  }

  void setPanel(Panel next) {
    if (next == panel && inspectorOpen) return;
    final leaving = panel;
    _set(() {
      if (!panel.isTool) _lastTab = panel;
      panel = next;
      inspectorOpen = true;
    });
    // A tool changes what the shown picture is developed with.
    if (leaving.isTool || next.isTool) renderer?.schedule();
  }

  Panel _lastTab = Panel.film;

  /// Opens a canvas tool, or closes it back to the tab it was opened from.
  void toggleTool(Panel tool) => setPanel(panel == tool ? _lastTab : tool);
  void toggleFilm() => _set(() => filmOpen = !filmOpen);
  void toggleInspector() {
    _set(() => inspectorOpen = !inspectorOpen);
    // A tool shows its picture only while the inspector does.
    if (panel.isTool) renderer?.schedule();
  }

  void setPresetsTab(bool value) {
    _set(() => presetsTab = value);
    // The preset rows' pictures develop in the background.
    renderer?.schedule();
  }
  void setSearch(String value) => _set(() => search = value);
  void setFilmType(FilmType value) => _set(() => filmType = value);
  void dismissError() => _set(() => error = null);

  /// A feature's model (lib/model/<area>.dart) changed what the workspace shows.
  void notify() => notifyListeners();

  void setComparing(bool value) {
    if (comparing == value || active == null) return;
    _set(() => comparing = value);
  }

  void toggleHistogram() {
    _set(() => histogramOpen = !histogramOpen);
    if (histogramOpen) renderer?.schedule();
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
    // The crop tool shows the whole frame, fitted.
    if (value != null && crop.showing) return;
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
    if (crop.showing) return;
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
}

/// A change to a photograph's history, as features are told of it.
class EditChange {
  const EditChange(this.doc, this.kind, this.before, {this.restoring = false});
  final PhotoDocument doc;

  /// edit, undo, redo, goTo or replace (a film the app chose, not a step to undo).
  final String kind;
  final Json before;

  /// A whole edit put in place: a paste, a preset, Load Edits.
  final bool restoring;
}

/// A photograph to open: its name, and its path where there is a file system, or its bytes.
class PhotoFile {
  PhotoFile(this.name, {this.path, this.read});
  final String name;
  final String? path;
  final Future<Uint8List> Function()? read;
}
