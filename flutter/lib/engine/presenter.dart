// The native image layer: the platform's presenter, lent to the engine so a develop is written
// straight into memory the compositor draws (fotufilm_engine_set_presenter). Nothing is encoded
// and only frame ids cross to Dart. The platform answers this channel:
//
//   attach {engine: address} → {layers: [name]}
//   show {frame} → {width, height}   places a presented frame on its layer
//   clear {layer}
//   headroomChanged (from the platform)   the screen can show more or less light above white
//
// and draws each layer in a platform view, "fotufilm/photo-layer" {layer}, in the engine's
// Display P3 and with EDR where the screen has it. macOS lends IOSurface-backed pixel buffers
// (macos/Runner/EnginePresenter.swift, PhotoLayer.swift).
import 'package:flutter/services.dart';

class NativePresenter {
  NativePresenter._(this.layers);

  static const _channel = MethodChannel('fotufilm/presenter');

  /// The platform view that draws a layer.
  static const viewType = 'fotufilm/photo-layer';

  /// `preview`, `preview.original`, `detail` and `detail.original`.
  final Set<String> layers;

  /// Hears the screen's headroom change, so the shown photograph develops for it again.
  void Function()? onHeadroomChange;

  /// Lends the platform's presenter to the engine; null where the host has none.
  static Future<NativePresenter?> attach(int engineAddress) async {
    try {
      final answer = await _channel.invokeMapMethod<String, Object?>(
          'attach', {'engine': engineAddress});
      if (answer == null) return null;
      final presenter = NativePresenter._({...(answer['layers'] as List).cast<String>()});
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'headroomChanged') presenter.onHeadroomChange?.call();
      });
      return presenter;
    } on MissingPluginException {
      return null;
    }
  }

  /// Puts a presented frame on its layer once its geometry is known; false if it is gone.
  Future<bool> show(int frame) async =>
      await _channel.invokeMethod<Object?>('show', {'frame': frame}) != null;

  Future<void> clear(String layer) => _channel.invokeMethod('clear', {'layer': layer});
}
