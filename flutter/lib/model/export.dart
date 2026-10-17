// Export and output, as the React editor does them on the desktop (web/src/editor/
// useExportActions.js, useExportOptions.js, useOutputState.js, backend/desktop/host.js): one
// photograph to a file, every photograph into a folder (Export All), a camera RAW as itself
// (Export Original), the developed picture to the clipboard (Copy Photo), and a movie frame by
// frame (`exportVideo`, useExportActions.js `exportClip`). The engine develops,
// encodes and writes; the editor chooses where, as the CEF shell's save panels do.
//
// Where the engine runs exports beside its develops (the desktop), still exports wait in a
// queue and run one after another while the person keeps editing: each takes its photographs'
// edits as they were when it was asked for, and a photograph closed meanwhile stays loaded until
// its export is done. A movie, and every export in a browser, holds the editor until it is done.
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../app/environment.dart';
import '../engine/engine.dart';
import 'edit.dart';
import 'editor.dart';
import 'export_sizes.dart';

export 'export_sizes.dart';

/// The still formats the desktop engine may write, in the order the dialog lists them
/// (backend/desktop/host.js `EXPORT_LABELS`).
const exportTypeLabels = {
  'image/png': 'PNG',
  'image/tiff': 'TIFF · 16-bit',
  'image/jpeg': 'JPEG',
  'image/heic': 'HEIC',
};

/// Export Original's format: the camera RAW file itself.
const originalType = 'original';

/// The export sheet's names for each metadata policy (useExportOptions.js `METADATA_LABELS`).
const metadataLabels = {
  'preserve': 'Include Location',
  'preserveWithoutLocation': 'Capture Details',
  'strip': 'No Metadata',
};

const lossyTypes = {'image/jpeg', 'image/webp', 'image/heic'};

/// A photograph's file name with no extension, safe for any file system (file-download.js).
String cleanName(String name) {
  final stem = name
      .replaceFirst(RegExp(r'\.[^.]+$'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '-');
  final cut = stem.runes.length > 100 ? String.fromCharCodes(stem.runes.take(100)) : stem;
  return cut.isEmpty ? 'photo' : cut;
}

/// A still's file name: the photograph's, its film and its print medium (useExportActions.js).
String stillFilename(String name, Json edit, String type) {
  final stock = edit['stock'] as String?;
  final medium = edit['medium'] as String?;
  final ext = type == 'image/jpeg' ? 'jpg' : type.split('/').last;
  return '${cleanName(name)}-${stock == null || stock.isEmpty ? 'normal' : stock}'
      '${medium == null || medium.isEmpty ? '' : '-$medium'}.$ext';
}

/// What the engine can write for this edit beyond the format list (`exportOptions`).
class ExportOptions {
  ExportOptions.fromJson(Json json)
      : metadata = (json['metadata'] as List?)?.cast<String>(),
        hdr = json['hdr'] == true,
        unavailable = ((json['unavailable'] as List?) ?? const []).cast<String>();

  /// The metadata policies; null hides the picker.
  final List<String>? metadata;

  /// Whether a HEIC may carry HDR: the film delivers light above display white.
  final bool hdr;

  /// The size ids past the developer's memory limit at this photo quality.
  final List<String> unavailable;
}

/// A still export queued or running in the background.
class ExportJob {
  ExportJob._(this.title, this.handles, this._work);

  /// What it writes: a file's name, or how many photos.
  final String title;

  /// The photographs it develops, kept loaded until it is done.
  final List<int> handles;
  final Future<SavedExport?> Function(EngineConnection engine, ExportJob job) _work;
  final _done = Completer<SavedExport?>();

  bool running = false;

  /// What it is doing now, and how far it is (0 to 1; null while unknown).
  String? detail;
  double? progress;
}

/// What an export just saved, for the notice: one file, or `count` files in `directory`.
class SavedExport {
  const SavedExport({required this.filename, required this.path, this.count, this.directory});
  final String filename, path;
  final int? count;
  final String? directory;
}

class ExportTool {
  ExportTool(this.editor);
  final EditorModel editor;

  // The dialog's choices, kept while the editor is open (useEditorState.js).
  String type = 'image/png';
  String size = 'full';
  int quality = 95;
  String metadata = 'preserveWithoutLocation';

  /// A movie's format (useEditorState.js `videoFormat`), one of [videoTypes].
  String videoFormat = 'mp4';

  /// The engine's answer for the shown photograph; null while unknown.
  ExportOptions? options;

  /// The last export saved, until it is dismissed (SavedExportNotice.jsx).
  SavedExport? saved;

  /// The still exports in the background, the running one first.
  final List<ExportJob> jobs = [];

  /// Whether a background export is queued or running.
  bool get busy => jobs.isNotEmpty;

  /// How many queued or running exports need each photograph, by handle.
  final Map<int, int> _needed = {};

  /// Photographs closed while an export still needed them, let go when it is done.
  final Set<int> _closed = {};
  bool _pumping = false;

  /// A folder every export goes to without asking, as the CEF shell's --export-dir: for
  /// scripted checks.
  String? fixedDirectory = environment('FOTUFILM_EXPORT_DIR');

  EngineConnection? get _engine => editor.engine;
  Map<String, dynamic> get _capabilities => _engine?.capabilities ?? const {};
  AppSettings get _settings => editor.settings;

  // ── What may be offered ───────────────────────────────────────────────────────────────────

  /// The formats the engine's encoder writes, (id, label).
  List<(String, String)> get types {
    final offered = (_capabilities['imageExportTypes'] as List?)?.cast<String>() ?? const [];
    return [
      for (final MapEntry(:key, :value) in exportTypeLabels.entries)
        if (offered.isEmpty || offered.contains(key)) (key, value),
    ];
  }

  /// How many photographs Export All would write; 0 where the engine has no Export All. Movies
  /// export one at a time, so it leaves them out.
  int get batchCount => _capabilities['batchExport'] == true ? _batch.length : 0;

  /// Whether Export All writes the photos chosen in the strip rather than all it shows.
  bool get batchChosen => editor.selection.chosen.length > 1;

  /// The photographs Export All writes: those chosen in the strip, or every open one it shows.
  List<PhotoDocument> get _batch => [
        for (final d in batchChosen
            ? editor.selection.chosen
            : [for (final item in editor.strip.items) ?item.doc])
          if (!d.isMovie) d,
      ];

  /// Whether a HEIC across photographs may carry HDR, for those whose film delivers it.
  bool get batchHDR => _capabilities['hdrExport'] == true;

  /// A camera RAW opened from a file can be exported as itself.
  bool originalAvailable(PhotoDocument doc) => doc.raw && (_engine?.opensPaths ?? false);

  bool get canCopy =>
      _capabilities['copyImage'] == true && editor.active != null && !editor.active!.isMovie;

  /// HDR HEIC, kept as the app's Photo HDR setting.
  bool get hdr => _settings.get<bool>('photoHDR') == true;
  set hdr(bool value) {
    _settings.set('photoHDR', value);
    editor.notify();
  }

  String get photoQuality => _settings.get<String>('photoQuality') ?? 'accurate';

  /// The settings of the last photo, or movie, exported, offered back (Use Last Export
  /// Settings).
  Json? get last =>
      _settings.get<Map>(_movie ? 'lastVideoExport' : 'lastPhotoExport')?.cast<String, dynamic>();

  /// The settings the dialog shows now, as `last` keeps them.
  Json get current => _movie
      ? {
          'format': videoFormat,
          'quality': 'high',
          'bitrate': videoBitrate,
          'frameRate': videoFrameRate,
          if (videoProcessingOffered) 'processing': videoProcessing,
          'size': size,
        }
      : {'type': type, 'size': size, 'quality': quality, 'metadata': metadata};

  // ── Movies (backend/desktop/host.js `videoExportTypes`, ExportDialog.jsx) ───────────────────

  bool get _movie => editor.active?.isMovie == true;

  /// The movie formats the engine's platform writes: `{id, label, extension, type, quality,
  /// bits, colorSpace, hdr}`.
  List<Json> get videoTypes => _capabilities['video'] == true
      ? ((_capabilities['videoExportTypes'] as List?) ?? const []).cast<Json>()
      : const [];

  /// The chosen format, or the first offered when the chosen one is not.
  Json? get videoType =>
      videoTypes.where((t) => t['id'] == videoFormat).firstOrNull ?? videoTypes.firstOrNull;

  /// Video File Size's choices, `{id, label}`, and the frame rates an export may retime to.
  List<Json> get videoBitrates =>
      ((_capabilities['videoBitrates'] as List?) ?? const []).cast<Json>();
  List<int> get videoFrameRates => [
        for (final rate in (_capabilities['videoFrameRates'] as List?) ?? const [])
          (rate as num).toInt(),
      ];

  /// Whether Video Quality (Full or Fast) is offered.
  bool get videoProcessingOffered => _capabilities['videoProcessing'] == true;

  /// HDR movies, Video File Size and Video Quality: the app's settings.
  bool get videoHDR => _settings.get<bool>('videoHDR') == true;
  set videoHDR(bool value) {
    _settings.set('videoHDR', value);
    editor.notify();
  }

  String get videoBitrate => _settings.get<String>('videoBitrate') ?? 'automatic';
  set videoBitrate(String value) {
    _settings.set('videoBitrate', value);
    editor.notify();
  }

  String get videoProcessing => _settings.get<String>('videoProcessing') ?? 'full';
  set videoProcessing(String value) {
    _settings.set('videoProcessing', value);
    editor.notify();
  }

  /// The clip's cadence, kept with its edit as the Mac app keeps it: choosing a rate here sets
  /// it (ExportDialog.jsx `setVideoFrameRate`).
  int? get videoFrameRate => (videoSettings(editor.edit)['frameRate'] as num?)?.toInt();
  set videoFrameRate(int? rate) =>
      editor.change({'video': {...videoSettings(editor.edit), 'frameRate': rate}});

  // ── Sizes (useOutputState.js) ─────────────────────────────────────────────────────────────

  /// The cropped picture of `doc`, upright, which export sizes are measured on.
  PixelSize cropSize(PhotoDocument doc) {
    final turned = ((doc.edit['rotation'] as num?) ?? 0).toInt().isOdd;
    final (w, h) = turned ? (doc.height, doc.width) : (doc.width, doc.height);
    final crop = doc.edit['crop'];
    return crop is List && crop.length == 4 ? outputSize(crop, w, h) : (width: w, height: h);
  }

  List<ExportSize> sizes({required bool batch}) {
    final doc = editor.active;
    return batch || doc == null
        ? batchExportSizeOptions()
        : exportSizeOptions(cropSize(doc), video: doc.isMovie);
  }

  /// The sizes past the memory limit; Export All reduces each photograph as it needs instead.
  List<String> unavailable({required bool batch}) =>
      batch || _movie ? const [] : options?.unavailable ?? const [];

  /// The size an export uses: the one chosen where it is offered, else the full picture, and
  /// the largest that fits in place of one that does not, as the Mac app selects.
  String sizeId({required bool batch}) {
    final offered = sizes(batch: batch);
    final blocked = unavailable(batch: batch);
    final chosen = offered.any((s) => s.id == size) ? size : 'full';
    if (!blocked.contains(chosen)) return chosen;
    return offered.where((s) => !blocked.contains(s.id)).firstOrNull?.id ?? chosen;
  }

  /// What the chosen size delivers of the shown photograph.
  PixelSize delivered(PhotoDocument doc) {
    final crop = cropSize(doc);
    final edge = exportMaxEdge(sizeId(batch: false), crop);
    final pixels = edge == null ? crop : exportPixels(edge, crop);
    // A movie in whole pairs of pixels.
    return doc.isMovie ? evenSize(pixels) : pixels;
  }

  // ── Requests ──────────────────────────────────────────────────────────────────────────────

  /// A photograph's render request as an export sends it: the finished picture, framed where
  /// its print frame says (session.js `renderRequest`).
  Json _request(PhotoDocument doc, {int? maxEdge}) {
    // A movie is never framed (session.js `renderRequest`).
    final frame = doc.isMovie ? null : editor.renderOptions(doc)['printFrame'];
    return {
      ...renderRequest(
        catalogue: editor.catalogue,
        handle: doc.handle,
        edit: doc.edit,
        stock: editor.stockById(doc.edit['stock'] as String?),
        maxEdge: maxEdge,
      ),
      'printFrame': ?frame,
    };
  }

  /// Asks what the engine can write for the shown photograph (useExportOptions.js).
  Future<void> loadOptions() async {
    final doc = editor.active, engine = _engine;
    if (doc == null || engine == null || types.isEmpty || doc.isMovie) return;
    final edit = doc.edit;
    try {
      final answer = await engine.call('exportOptions', {
        ..._request(doc, maxEdge: 1024),
        'sizes': [
          for (final s in sizes(batch: false))
            if (s.pixels case final pixels?)
              {'id': s.id, 'width': pixels.width, 'height': pixels.height},
        ],
        'photoQuality': photoQuality,
      });
      if (editor.active != doc || !identical(doc.edit, edit)) return;
      options = ExportOptions.fromJson(answer.json);
    } catch (_) {
      options = null;
    }
    editor.notify();
  }

  // ── Exports ───────────────────────────────────────────────────────────────────────────────

  /// Runs an export: the editor waits and the renderer leaves the engine's work alone, so that
  /// a develop the view asks for does not cancel it. Cancelling is not a failure.
  Future<T?> _run<T>(String status, Future<T> Function() body) async {
    if (editor.exporting) return null;
    editor
      ..exporting = true
      ..error = null
      ..status = status;
    editor.renderer?.holdCancel = true;
    editor.notify();
    try {
      return await body();
    } on FotufilmCancelled {
      return null;
    } catch (e) {
      editor.error = '$e';
      return null;
    } finally {
      editor
        ..exporting = false
        ..status = null;
      editor.renderer?.holdCancel = false;
      editor.notify();
    }
  }

  void _setStatus(String status) {
    editor.status = status;
    editor.notify();
  }

  /// Runs a still export: in the background where the engine allows it, `onStarted` hearing
  /// once it is queued; otherwise as [_run] does, the editor waiting.
  Future<SavedExport?> _queue(String title, List<int> handles,
      Future<SavedExport?> Function(EngineConnection engine, ExportJob job) work,
      {void Function()? onStarted}) async {
    final engine = _engine;
    if (engine == null) return null;
    final job = ExportJob._(title, handles, work);
    if (!engine.exportsInBackground) {
      return _run<SavedExport?>(title, () async {
        final saved = await work(engine, job);
        return saved == null ? null : _show(saved);
      });
    }
    for (final handle in handles) {
      _needed[handle] = (_needed[handle] ?? 0) + 1;
    }
    jobs.add(job);
    editor.notify();
    onStarted?.call();
    unawaited(_pump());
    return job._done.future;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    while (jobs.isNotEmpty) {
      final job = jobs.first..running = true;
      editor.notify();
      SavedExport? saved;
      try {
        saved = await job._work(_engine!, job);
        if (saved != null) _show(saved);
      } on FotufilmCancelled {
        // Stopped by Cancel; what Export All already wrote stays.
      } catch (e) {
        editor.showError('$e');
      }
      jobs.remove(job);
      _letGo(job);
      job._done.complete(saved);
      editor.notify();
    }
    _pumping = false;
  }

  /// A queued or running export's progress, in the editor's status where it waits.
  void _report(ExportJob job, String detail, [double? progress]) {
    job
      ..detail = detail
      ..progress = progress;
    if (!(_engine?.exportsInBackground ?? false)) editor.status = detail;
    editor.notify();
  }

  /// Stops a background export: the running one at its next develop, a waiting one before it
  /// starts.
  void cancelJob(ExportJob job) {
    if (job.running) {
      _engine?.cancelBackground();
    } else if (jobs.remove(job)) {
      _letGo(job);
      job._done.complete(null);
      editor.notify();
    }
  }

  /// Whether an export still needs the photograph of `handle`.
  bool needs(int handle) => _needed.containsKey(handle);

  /// A photograph closed while an export needs it: let go when that export is done.
  void releaseAfter(int handle) => _closed.add(handle);

  void _letGo(ExportJob job) {
    for (final handle in job.handles) {
      final left = (_needed[handle] ?? 1) - 1;
      if (left > 0) {
        _needed[handle] = left;
        continue;
      }
      _needed.remove(handle);
      if (_closed.remove(handle)) _engine?.call('release', {'handle': handle});
    }
  }

  void _remember({required bool batch}) => _settings.set('lastPhotoExport', {
        'type': type,
        'size': sizeId(batch: batch),
        'quality': quality,
        'metadata': metadata,
      });

  SavedExport _show(SavedExport export) {
    saved = export;
    editor.notify();
    return export;
  }

  void dismissSaved() {
    saved = null;
    editor.notify();
  }

  /// The shown photograph, at the chosen size and format, where the save panel says (or to
  /// `path`). Answers what was saved, or null when nothing was.
  Future<SavedExport?> exportPhoto({String? path, void Function()? onStarted}) async {
    final doc = editor.active, engine = _engine;
    if (doc == null || engine == null || editor.exporting) return null;
    if (doc.isMovie) return exportMovie(path: path);
    if (type == originalType) return exportOriginal(path: path, onStarted: onStarted);
    final filename = stillFilename(doc.name, doc.edit, type);
    path ??= await _chooseFile(filename, type);
    if (path == null) return null;
    final destination = path;
    final request = {
      ..._request(doc, maxEdge: exportMaxEdge(sizeId(batch: false), cropSize(doc))),
      'type': type,
      'quality': quality / 100,
      'metadata': metadata,
      'hdr': hdr,
      'photoQuality': photoQuality,
      'filename': filename,
      'path': destination,
    };
    _remember(batch: false);
    return _queue(filename, [doc.handle], (engine, job) async {
      _report(job, 'Exporting $filename');
      final answer = await engine.callInBackground('export', request);
      return SavedExport(
          filename: answer.json['filename'] as String? ?? filename,
          path: answer.json['path'] as String? ?? destination);
    }, onStarted: onStarted);
  }

  /// Export All: the photographs chosen in the strip, or all it shows, each with its own edit,
  /// into one folder the panel asks for (or `directory`). The engine numbers names past files
  /// already there.
  Future<SavedExport?> exportAll({String? directory, void Function()? onStarted}) async {
    final engine = _engine;
    final docs = _batch;
    if (engine == null || docs.isEmpty || editor.exporting) return null;
    directory ??= await _chooseFolder();
    if (directory == null) return null;
    final request = {
      'items': [
        for (final doc in docs)
          {
            ..._request(doc),
            'name': doc.name,
            'filename': stillFilename(doc.name, doc.edit, type),
          },
      ],
      'size': sizeId(batch: true),
      'type': type,
      'quality': quality / 100,
      'metadata': metadata,
      'hdr': hdr,
      'photoQuality': photoQuality,
      'directory': directory,
    };
    _remember(batch: true);
    return _queue('${docs.length} photos', [for (final d in docs) d.handle], (engine, job) async {
      _report(job, 'Preparing export', 0);
      final answer = await engine.callInBackground('exportBatch', request, (progress) {
        final total = progress['total'], name = progress['name'];
        _report(
            job,
            name is String
                ? 'Exporting $name · ${progress['current']} of $total'
                : 'Exported ${progress['done']} of $total',
            (progress['progress'] as num?)?.toDouble());
      });
      final written = ((answer.json['written'] as List?) ?? const []).cast<Json>();
      final failed = ((answer.json['failed'] as List?) ?? const []).cast<Json>();
      final reduced = ((answer.json['reduced'] as List?) ?? const []).cast<String>();
      final problems = [
        for (final f in failed) '${f['name']}: ${f['error']}',
        if (reduced.isNotEmpty)
          'Exported smaller to stay within this device’s safe memory limit: '
              '${reduced.join(', ')}.',
      ];
      if (problems.isNotEmpty) editor.showError(problems.join(' '));
      if (written.isEmpty) return null;
      return SavedExport(
        filename: '${written.length} photos',
        path: written.first['path'] as String,
        count: written.length,
        directory: answer.json['directory'] as String? ?? directory,
      );
    }, onStarted: onStarted);
  }

  /// The shown movie: every frame of its trim developed with its film, crop and adjustments,
  /// encoded where the save panel says (or to `path`), with its sound. Progress shows in the
  /// status; Cancel stops it and leaves no file.
  Future<SavedExport?> exportMovie({String? path}) async {
    final doc = editor.active, engine = _engine;
    final type = videoType;
    if (doc == null || !doc.isMovie || engine == null || type == null || editor.exporting) {
      return null;
    }
    videoFormat = type['id'] as String;
    // A native format names its container, which is not always its id (HEVC, ProRes).
    final stock = doc.edit['stock'] as String?;
    final filename = '${cleanName(doc.name)}-${stock == null || stock.isEmpty ? 'normal' : stock}'
        '.${type['extension'] ?? videoFormat}';
    path ??= await _chooseFile(filename, '');
    if (path == null) return null;
    editor.video.pause();
    return _run('Preparing export', () async {
      final answer = await engine.callWithProgress('exportVideo', {
        ..._request(doc, maxEdge: exportMaxEdge(sizeId(batch: false), cropSize(doc))),
        'format': videoFormat,
        'bitrate': videoBitrate,
        'filename': filename,
        'videoProcessing': videoProcessing == 'fast' ? 'fast' : 'full',
        'type': type['type'] ?? 'video/mp4',
        'hdr': videoHDR,
        'path': path,
      }, (progress) {
        _setStatus(progress['finalizing'] == true
            ? 'Finalizing video file'
            : 'Exporting video · ${(((progress['progress'] as num?) ?? 0) * 100).floor()}% · '
                '${progress['frames']} frames');
      });
      _settings.set('lastVideoExport', current);
      return _show(SavedExport(
          filename: answer.json['filename'] as String? ?? filename,
          path: answer.json['path'] as String? ?? path!));
    });
  }

  /// Export Original: the camera RAW file itself, no edit and no size.
  Future<SavedExport?> exportOriginal({String? path, void Function()? onStarted}) async {
    final doc = editor.active, engine = _engine;
    if (doc == null || engine == null || !originalAvailable(doc) || editor.exporting) return null;
    path ??= await _chooseFile(doc.name, '');
    if (path == null) return null;
    final destination = path, name = doc.name, handle = doc.handle;
    return _queue(name, [handle], (engine, job) async {
      _report(job, 'Copying the original');
      final answer = await engine.callInBackground(
          'exportOriginal', {'handle': handle, 'filename': name, 'type': '', 'path': destination});
      return SavedExport(
          filename: answer.json['filename'] as String? ?? name,
          path: answer.json['path'] as String? ?? destination);
    }, onStarted: onStarted);
  }

  /// Use Last Export Settings: the last photo export's settings, exported again.
  Future<SavedExport?> exportWithLast() {
    applyLast();
    return exportPhoto();
  }

  /// Puts the last photo export's settings back in the dialog.
  void applyLast() {
    final last = this.last;
    if (last == null) return;
    if (_movie) {
      if (last['format'] case final String value) videoFormat = value;
      if (last['bitrate'] case final String value) _settings.set('videoBitrate', value);
      if (last['processing'] case final String value) _settings.set('videoProcessing', value);
      if (last['size'] case final String value) size = value;
      videoFrameRate = (last['frameRate'] as num?)?.toInt();
      editor.notify();
      return;
    }
    if (last['type'] case final String value) type = value;
    if (last['size'] case final String value) size = value;
    if (last['quality'] case final num value) quality = value.round();
    if (last['metadata'] case final String value) metadata = value;
    editor.notify();
  }

  /// Stops an export in flight: the engine stops at its next develop, keeping what Export All
  /// already wrote.
  void cancel() {
    if (editor.exporting) _engine?.cancel();
  }

  /// Copy Photo: the developed picture, full size, on the clipboard, written by the engine.
  Future<void> copyPhoto() async {
    final doc = editor.active, engine = _engine;
    if (doc == null || engine == null || !canCopy || editor.exporting) return;
    editor
      ..error = null
      ..status = 'Copying the photo';
    editor.renderer?.holdCancel = true;
    editor.notify();
    try {
      await engine.call('copyImage', {..._request(doc), 'photoQuality': photoQuality});
    } on FotufilmCancelled {
      // A newer develop took the engine; nothing was copied.
    } catch (e) {
      editor.error = '$e';
    } finally {
      editor.status = null;
      editor.renderer?.holdCancel = false;
      editor.notify();
    }
  }

  // ── Destinations (the CEF shell's export panels) ──────────────────────────────────────────

  Future<String?> _chooseFile(String filename, String type) async {
    if (fixedDirectory case final dir? when dir.isNotEmpty) return '$dir/$filename';
    // A browser saves to its downloads.
    if (kIsWeb) return filename;
    final ext = filename.contains('.') ? filename.split('.').last : '';
    final location = await getSaveLocation(
      suggestedName: filename,
      acceptedTypeGroups: [
        if (ext.isNotEmpty) XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    return location?.path;
  }

  Future<String?> _chooseFolder() async {
    if (fixedDirectory case final dir? when dir.isNotEmpty) return dir;
    return getDirectoryPath(confirmButtonText: 'Export');
  }
}
