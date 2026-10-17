// What the canvas tools draw over the photograph and take from the pointer: the crop frame, the
// selective tool's sampling, the negative's clear-film sampling. Each tool lives in its own file;
// this is the one place that names them all.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import 'film_base_sampler.dart';

/// The overlays for what the editor is doing now, over `photo` (the picture's rectangle in the
/// viewer). They sit above the picture and take the pointer where they need it.
List<Widget> viewerToolOverlays(EditorModel editor, Rect photo) => [
      if (editor.negatives.sampling && editor.negatives.negative != null)
        Positioned.fromRect(rect: photo, child: FilmBaseSampler(editor: editor)),
    ];
