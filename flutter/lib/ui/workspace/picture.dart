// Drawing the engine's pictures. They are Display P3 and the window is sRGB, so each passes
// through an exact conversion on the GPU (shaders/display_p3_to_srgb.frag) unless the platform's
// presenter has already converted it.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

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

  /// `child` drawn in sRGB. `swapRedBlue` for RGBA pixels in a BGRA texture.
  static Widget apply(Widget child, {bool swapRedBlue = false}) {
    final program = _program;
    if (!enabled || program == null || !ui.ImageFilter.isShaderFilterSupported) return child;
    // Uniforms 0 and 1 are the size, which the filter sets; 2 is the swap.
    final shader = program.fragmentShader()..setFloat(2, swapRedBlue ? 1 : 0);
    return ImageFiltered(imageFilter: ui.ImageFilter.shader(shader), child: child);
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

/// A layer of the native presenter: the engine wrote it straight into a platform texture.
class PresentedLayer extends StatelessWidget {
  const PresentedLayer({
    super.key,
    required this.texture,
    required this.swapRedBlue,
    required this.converted,
  });

  final int texture;
  final bool swapRedBlue, converted;

  @override
  Widget build(BuildContext context) {
    final layer = Texture(textureId: texture, filterQuality: FilterQuality.medium);
    return converted ? layer : ColourConversion.apply(layer, swapRedBlue: swapRedBlue);
  }
}
