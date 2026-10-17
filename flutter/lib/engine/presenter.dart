// The native image layer: the platform's presenter, lent to the engine so a develop is written
// straight into memory the compositor draws (fotufilm_engine_set_presenter). Nothing is encoded
// and only frame ids cross to Dart. Every platform answers the same channel:
//
//   attach {engine: address} → {textures: {layer: id}, swapRedBlue, convertsColour}
//   show {frame} → {width, height}   places a presented frame on its layer
//   clear {layer}
//
// macOS lends IOSurface-backed pixel buffers (macos/Runner/EnginePresenter.swift); Linux and
// Windows lend Flutter pixel-buffer textures (native/pixel_presenter.h).
import 'package:flutter/services.dart';

class NativePresenter {
  NativePresenter._(this.textures, this.swapRedBlue, this.convertsColour);

  static const _channel = MethodChannel('fotufilm/presenter');

  /// Flutter texture ids of `preview`, `preview.original`, `detail` and `detail.original`.
  final Map<String, int> textures;

  /// The layer's pixels are RGBA in a BGRA texture (macOS), so drawing swaps them back.
  final bool swapRedBlue;

  /// The presenter has already converted Display P3 to the window's sRGB.
  final bool convertsColour;

  /// Lends the platform's presenter to the engine; null where the host has none.
  static Future<NativePresenter?> attach(int engineAddress) async {
    try {
      final answer = await _channel.invokeMapMethod<String, Object?>(
          'attach', {'engine': engineAddress});
      if (answer == null) return null;
      return NativePresenter._(
        (answer['textures'] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
        answer['swapRedBlue'] == true,
        answer['convertsColour'] == true,
      );
    } on MissingPluginException {
      return null;
    }
  }

  /// Puts a presented frame on its layer once its geometry is known; false if it is gone.
  Future<bool> show(int frame) async =>
      await _channel.invokeMethod<Object?>('show', {'frame': frame}) != null;

  Future<void> clear(String layer) => _channel.invokeMethod('clear', {'layer': layer});
}
