// A development hook for scripted checks, as the iPhone app's FOTUFILM_* launch hooks are: with
// FOTUFILM_DRIVER_DIR set, the editor reads commands from <dir>/commands (one JSON object a line,
// appended) and answers each in <dir>/log. Nothing runs without the variable.
//
//   {"snapshot": "name"}            the window's pixels to <dir>/name.png
//   {"tap": [x, y]}                 a click at logical point (x, y)
//   {"drag": [x0, y0, x1, y1]}      a press, a move and a release
//   {"open": ["/path/photo.jpg"]}   opens photographs
//   {"stock": "gold200"}            chooses a film ("" for Normal)
//   {"filmType": "slide"}          shows one film type in the library (FilmType's name)
//   {"panel": "light"}              film, light, develop or print
//   {"param": ["ev", 1.0]}          sets an edit parameter
//   {"profile": ["push", 1]}        sets a film control
//   {"probe": "/path/x.png"}       logs the first pixel as Flutter decodes it
//   {"export": ["/out.jpg", "image/jpeg"]}  exports the shown photograph with the dialog's settings
//   {"exportSettings": {"type": "image/heic", "size": "0.5", "quality": 80,
//                       "metadata": "strip", "hdr": true}}   the Export dialog's choices
//   {"exportDir": "/dir"}           every export saves there without a panel
//   {"exportAll": "/dir"}           Export All into a folder; add "cancelAfter": ms to cancel it
//   {"exportOriginal": "/x.ARW"}    Export Original of the shown camera RAW
//   {"useLastExport": true}         File › Use Last Export Settings (into exportDir)
//   {"copyPhoto": true}             Edit › Copy Photo
//   {"select": 1}                   shows the strip's second photograph
//   {"histogram": true}           shows the histogram
//   {"wheel": [x, y, dy]}           a mouse wheel turn at (x, y)
//   {"trackpad": [x, y, dy]}        a two-finger trackpad scroll at (x, y)
//   {"zoom": 1}                     magnifies (null fits)
//   {"pan": [dx, dy]}               moves a magnified photograph
//   {"compare": true}               shows the original, as holding Space does
//   {"bench": ["ev", 30]}           drags a slider in 30 steps a frame apart and logs how long
//                                   each develop took to reach the screen, then the settle
//   {"benchOpen": "/path"}          opens a photograph: ms to its first develop, and to idle
//   {"benchFilm": "gold200"}        chooses a film: ms to its first develop, and to idle
//   {"benchDrag": ["ev", 2000]}     moves a slider every 16 ms for 2 s, as a hand does, and logs
//                                   how many develops reached the screen, then the settle
//   {"wait": "idle"}                answers once nothing is rendering
//   {"sample": [0.5, 0.5]}          samples the selection at a point of the shown picture
//   {"selection": {"range": 0.4}}   changes the selection
//   {"mask": true}                  shows the selection's mask
//   {"stage": 3}                    shows a pipeline stage (null the finished print)
//   {"difference": true}            shows the stage as its change from the one before
//   {"tools": true}                 logs the selection, the subjects and the pipeline's stages
//   and scanned negatives' commands (negative_driver.dart)
//   {"key": "Enter"}                presses and releases a key: Enter, Escape or a letter
//   {"crop": "rotate"}              the crop tool: rotate, flip, corners, reset or done
//   {"cropRatio": "3:2"}            chooses the crop's aspect ratio
//   {"cropGeometry": ["straighten", 5]}  sets straighten, perspectiveV or perspectiveH
//   {"cropState": true}             logs the crop, the picture's size and the handles' window
//                                   positions (corners clockwise from top left, then edges)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/editor.dart';
import '../model/export.dart';
import '../ui/workspace/crop_overlay.dart';
import 'negative_driver.dart';

class Driver {
  Driver._(this.dir, this.editor, this.boundary);

  final Directory dir;
  final EditorModel editor;
  final GlobalKey boundary;
  int _read = 0;
  bool _busy = false;
  int _pointer = 900;

  static void start(EditorModel editor, GlobalKey boundary) {
    final path = Platform.environment['FOTUFILM_DRIVER_DIR'];
    if (path == null || path.isEmpty) return;
    final dir = Directory(path)..createSync(recursive: true);
    final driver = Driver._(dir, editor, boundary);
    driver._log('ready ${DateTime.now().millisecondsSinceEpoch}');
    Timer.periodic(const Duration(milliseconds: 250), (_) => driver._poll());
  }

  File get _commands => File('${dir.path}/commands');

  void _log(String line) =>
      File('${dir.path}/log').writeAsStringSync('$line\n', mode: FileMode.append, flush: true);

  Future<void> _poll() async {
    if (_busy || !_commands.existsSync()) return;
    final lines = _commands.readAsLinesSync();
    if (lines.length <= _read) return;
    _busy = true;
    try {
      while (_read < lines.length) {
        final line = lines[_read++].trim();
        if (line.isEmpty) continue;
        try {
          await _run(jsonDecode(line) as Map<String, dynamic>);
          _log('ok $line');
        } catch (e) {
          _log('error $line: $e');
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _run(Map<String, dynamic> c) async {
    if (c['snapshot'] case final String name) {
      // Let transitions finish.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final render = boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
      final image = await render.toImage(pixelRatio: dpr);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${dir.path}/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    }
    if (c['tap'] case [final num x, final num y]) {
      final at = Offset(x.toDouble(), y.toDouble());
      final id = _pointer++;
      GestureBinding.instance.handlePointerEvent(PointerAddedEvent(pointer: id, position: at, kind: PointerDeviceKind.mouse));
      GestureBinding.instance.handlePointerEvent(PointerHoverEvent(pointer: id, position: at, kind: PointerDeviceKind.mouse));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: id, position: at, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: id, position: at, kind: PointerDeviceKind.mouse));
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    if (c['drag'] case [final num x0, final num y0, final num x1, final num y1]) {
      final id = _pointer++;
      var at = Offset(x0.toDouble(), y0.toDouble());
      final end = Offset(x1.toDouble(), y1.toDouble());
      GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: id, position: at, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton));
      for (var i = 1; i <= 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        final next = Offset.lerp(Offset(x0.toDouble(), y0.toDouble()), end, i / 12)!;
        GestureBinding.instance
            .handlePointerEvent(PointerMoveEvent(pointer: id, position: next, delta: next - at, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton));
        at = next;
      }
      GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: id, position: at, kind: PointerDeviceKind.mouse));
    }
    if (c['probe'] case final String path) {
      // The first pixel of an image as Flutter decodes it, to see what its codec makes of tags.
      final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
      final image = (await codec.getNextFrame()).image;
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      _log('probe $path ${rgba!.buffer.asUint8List().sublist(0, 4)}');
    }
    final exporter = editor.exporter;
    if (c['exportSettings'] case final Map settings) {
      if (settings['type'] case final String type) exporter.type = type;
      if (settings['size'] case final String size) exporter.size = size;
      if (settings['quality'] case final num quality) exporter.quality = quality.round();
      if (settings['metadata'] case final String metadata) exporter.metadata = metadata;
      if (settings['hdr'] case final bool hdr) exporter.hdr = hdr;
      await exporter.loadOptions();
      final o = exporter.options;
      _log('exportOptions metadata=${o?.metadata} hdr=${o?.hdr} unavailable=${o?.unavailable} '
          'types=${exporter.types.map((t) => t.$1).toList()} batch=${exporter.batchCount}');
    }
    if (c['exportDir'] case final String dir) exporter.fixedDirectory = dir;
    if (c['select'] case final int index) editor.selectDocument(index);
    if (c['export'] case [final String path, final String type]) {
      exporter.type = type;
      _logSaved(await exporter.exportPhoto(path: path));
    }
    if (c['exportAll'] case final String dir) {
      if (c['cancelAfter'] case final int ms) {
        Timer(Duration(milliseconds: ms), exporter.cancel);
      }
      final clock = Stopwatch()..start();
      // The statuses its progress showed.
      final shown = <String>[];
      final watch = Timer.periodic(const Duration(milliseconds: 10), (_) {
        final status = editor.status;
        if (status != null && (shown.isEmpty || shown.last != status)) shown.add(status);
      });
      _logSaved(await exporter.exportAll(directory: dir));
      watch.cancel();
      _log('exportAll ${clock.elapsedMilliseconds}ms statuses=$shown');
    }
    if (c['exportOriginal'] case final String path) {
      _logSaved(await exporter.exportOriginal(path: path));
    }
    if (c['useLastExport'] == true) _logSaved(await exporter.exportWithLast());
    if (c['copyPhoto'] == true) {
      await exporter.copyPhoto();
      _log('copied error=${editor.error}');
    }
    if (c['histogram'] == true && !editor.histogramOpen) editor.toggleHistogram();
    if (c['open'] case final List paths) await editor.openPaths(paths.cast<String>());
    if (c['stock'] case final String id) editor.chooseStock(id.isEmpty ? null : id);
    if (c['filmType'] case final String name) {
      editor.setFilmType(FilmType.values.byName(name));
      _log('films ${editor.stocks.where(editor.filmType.holds).map((s) => s['name']).join(', ')}');
    }
    if (c['panel'] case final String id) {
      editor.setPanel(Panel.values.firstWhere((p) => p.id == id));
    }
    if (c['param'] case [final String key, final num value]) {
      editor.setParam(key, value.toDouble());
      editor.endEdit();
    }
    if (c['profile'] case [final String field, final Object? value]) {
      editor.setProfile(field, value, grouped: false);
    }
    if (c['wheel'] case [final num x, final num y, final num dy]) {
      final at = Offset(x.toDouble(), y.toDouble());
      GestureBinding.instance.handlePointerEvent(PointerScrollEvent(
          position: at, kind: PointerDeviceKind.mouse, scrollDelta: Offset(0, dy.toDouble())));
    }
    if (c['trackpad'] case [final num x, final num y, final num dy]) {
      final at = Offset(x.toDouble(), y.toDouble());
      final id = _pointer++;
      final binding = GestureBinding.instance;
      binding.handlePointerEvent(PointerPanZoomStartEvent(pointer: id, position: at));
      for (var i = 1; i <= 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        binding.handlePointerEvent(PointerPanZoomUpdateEvent(
            pointer: id, position: at, pan: Offset(0, -dy * i / 10), panDelta: Offset(0, -dy / 10)));
      }
      binding.handlePointerEvent(PointerPanZoomEndEvent(pointer: id, position: at));
    }
    if (c.containsKey('zoom')) editor.setZoom((c['zoom'] as num?)?.toDouble());
    if (c['pan'] case [final num dx, final num dy]) editor.panBy(Offset(dx.toDouble(), dy.toDouble()));
    if (c['compare'] case final bool on) editor.setComparing(on);
    if (c['bench'] case [final String key, final int steps]) await _bench(key, steps);
    if (c['benchOpen'] case final String path) {
      await _timed('open', () => editor.openPaths([path]));
    }
    if (c['benchFilm'] case final String id) await _timed('film $id', () async => editor.chooseStock(id));
    if (c['benchDrag'] case [final String key, final int ms]) await _benchDrag(key, ms);
    if (c['sample'] case [final num x, final num y]) {
      editor.selective.startSampling();
      await editor.selective.sample([x.toDouble(), y.toDouble()]);
    }
    if (c['selection'] case final Map changes) editor.selective.change(changes.cast());
    if (c['mask'] case final bool on) editor.selective.setShowMask(on);
    if (c.containsKey('stage')) editor.pipeline.setStage((c['stage'] as num?)?.toInt());
    if (c['difference'] case final bool on) editor.pipeline.setDifference(on);
    if (c['tools'] == true) {
      final pipeline = editor.pipeline;
      _log('selective ${jsonEncode(editor.edit['selective'])} sampling=${editor.selective.sampling} '
          'mask=${editor.selective.showMask} subjects=${editor.selective.subjects}');
      _log('pipeline stage=${pipeline.stage} difference=${pipeline.difference} stages='
          '${[for (var i = 0; i < pipeline.stages.length; i++) pipeline.stageName(i)].join(', ')}');
    }
    await driveNegatives(editor, c, _log);
    if (c['key'] case final String name) await _key(name);
    if (c['crop'] case final String action) {
      final crop = editor.crop;
      switch (action) {
        case 'rotate':
          crop.rotateLeft();
        case 'flip':
          crop.flip();
        case 'corners':
          crop.fourCorners();
        case 'reset':
          crop.reset();
        case 'done':
          crop.done();
      }
    }
    if (c['cropRatio'] case final String ratio) editor.crop.setRatio(ratio);
    if (c['cropGeometry'] case [final String key, final num value]) {
      editor.crop.setGeometry(key, value.toDouble());
      editor.endEdit();
    }
    if (c['cropState'] == true) {
      final handles = CropOverlay.surface.currentState?.handlesInWindow() ?? const [];
      final e = editor.edit;
      _log('crop showing=${editor.crop.showing} panel=${editor.panel.id} '
          'photo=${editor.photoSize.width.round()}x${editor.photoSize.height.round()} '
          'rect=${editor.view.photoRect(editor.photoSize)} '
          'rotation=${e['rotation']} flip=${e['flip']} ratio=${e['ratio']} shape=${e['cropShape']} '
          'crop=${jsonEncode(e['crop'])} undo=${editor.active?.history.past.length} '
          'handles=${[for (final h in handles) '${h.dx.round()},${h.dy.round()}'].join(' ')}');
    }
    if (c['wait'] == 'idle') {
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      while (editor.busy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  void _logSaved(SavedExport? saved) => _log(saved == null
      ? 'saved nothing error=${editor.error}'
      : 'saved ${saved.path} (${saved.filename}) count=${saved.count} error=${editor.error}');
  /// A key pressed and let go, as the keyboard sends it.
  Future<void> _key(String name) async {
    final (logical, physical, character) = switch (name) {
      'Enter' => (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter, '\n'),
      'Escape' => (LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape, null),
      _ => (
          LogicalKeyboardKey(name.toLowerCase().codeUnitAt(0)),
          PhysicalKeyboardKey(0x00070004 + name.toLowerCase().codeUnitAt(0) - 0x61),
          name.toLowerCase(),
        ),
    };
    for (final type in [ui.KeyEventType.down, ui.KeyEventType.up]) {
      // ignore: deprecated_member_use
      ServicesBinding.instance.keyEventManager.handleKeyData(ui.KeyData(
        timeStamp: Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
        type: type,
        physical: physical.usbHidUsage,
        logical: logical.keyId,
        character: type == ui.KeyEventType.down ? character : null,
        synthesized: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    final focus = FocusManager.instance.primaryFocus;
    _log('key $name focus=${focus?.context?.widget.runtimeType} '
        'pressed=${HardwareKeyboard.instance.logicalKeysPressed.length}');
  }

  /// Times an action to its first develop on screen and to idle (thumbnails and all).
  Future<void> _timed(String name, Future<void> Function() action) async {
    final renderer = editor.renderer!;
    final before = renderer.developed;
    final clock = Stopwatch()..start();
    await action();
    final acted = clock.elapsedMilliseconds;
    while (renderer.developed == before && clock.elapsedMilliseconds < 60000) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final first = clock.elapsedMilliseconds;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    while (editor.busy && clock.elapsedMilliseconds < 120000) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // The background waits 250 ms after a settle before it starts; that wait is not work.
    _log('bench $name action=${acted}ms firstDevelop=${first}ms idle=${clock.elapsedMilliseconds}ms');
  }

  /// A slider moved a step every frame for `ms`, as a dragging hand: how many develops reached the
  /// screen while it moved, and how long the full-size develop took after it was let go.
  Future<void> _benchDrag(String key, int ms) async {
    final renderer = editor.renderer!;
    final start = (editor.edit['params'] as Map)[key] as num? ?? 0;
    final before = renderer.developed;
    final clock = Stopwatch()..start();
    var steps = 0;
    while (clock.elapsedMilliseconds < ms) {
      steps++;
      editor.setParam(key, start + (steps % 60) / 60);
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    final shown = renderer.developed - before;
    final settle = Stopwatch()..start();
    editor.endEdit();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    while (renderer.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    _log('bench drag $key ${ms}ms steps=$steps develops=$shown '
        'fps=${(shown * 1000 / ms).toStringAsFixed(1)} settle=${settle.elapsedMilliseconds}ms');
    editor.undo();
  }

  /// A slider dragged a step a frame: each step's time until a develop for it (or a newer one)
  /// is on screen, then the time from release until the full-size develop is.
  Future<void> _bench(String key, int steps) async {
    final renderer = editor.renderer!;
    final latencies = <int>[];
    final start = (editor.edit['params'] as Map)[key] as num? ?? 0;
    for (var i = 1; i <= steps; i++) {
      final before = renderer.developed;
      final clock = Stopwatch()..start();
      editor.setParam(key, start + i / steps);
      while (renderer.developed == before && clock.elapsedMilliseconds < 5000) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      latencies.add(clock.elapsedMilliseconds);
      await WidgetsBinding.instance.endOfFrame;
    }
    final settle = Stopwatch()..start();
    editor.endEdit();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    while (renderer.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    settle.stop();
    latencies.sort();
    _log('bench $key steps=$steps median=${latencies[steps ~/ 2]}ms '
        'p90=${latencies[(steps * .9).floor().clamp(0, steps - 1)]}ms max=${latencies.last}ms '
        'settle=${settle.elapsedMilliseconds}ms');
    editor.undo();
  }
}
