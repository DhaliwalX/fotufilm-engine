// Drawing the engine's pictures. The presenter's layers are the platform's own, in Display P3.
// A decoded picture is Display P3 and the window is sRGB, so it passes through an exact
// conversion on the GPU (shaders/display_p3_to_srgb.frag).
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart' show StandardMessageCodec;
import 'package:flutter/widgets.dart';

import '../../engine/presenter.dart';

abstract final class ColourConversion {
  static ui.FragmentProgram? _program;

  /// Off where the engine already delivers sRGB (a browser).
  static bool enabled = true;

  static Future<void> load() async {
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/display_p3_to_srgb.frag');
    } catch (_) {
      _program = null;
    }
  }

  /// `child` drawn in sRGB.
  static Widget apply(Widget child) {
    final program = _program;
    if (!enabled || program == null || !ui.ImageFilter.isShaderFilterSupported) return child;
    // Its only uniform is the size, which the filter sets.
    return ImageFiltered(imageFilter: ui.ImageFilter.shader(program.fragmentShader()), child: child);
  }
}

/// A decoded picture from the engine (a PNG answer), fitted to its box.
class EnginePicture extends StatelessWidget {
  const EnginePicture(this.image, {super.key, this.fit = BoxFit.fill});
  final ui.Image image;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => ColourConversion.apply(
      RawImage(image: image, fit: fit, filterQuality: FilterQuality.medium));
}

/// A layer of the native presenter, which the platform draws in the engine's Display P3, with
/// EDR where the screen has it; the gestures over it stay the editor's.
class PresentedLayer extends StatelessWidget {
  const PresentedLayer(this.layer, {super.key});

  final String layer;

  @override
  Widget build(BuildContext context) => AppKitView(
        // Comparing shows another layer: its own view.
        key: ValueKey(layer),
        viewType: NativePresenter.viewType,
        creationParams: {'layer': layer},
        creationParamsCodec: const StandardMessageCodec(),
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      );
}
