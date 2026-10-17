// An open photograph: its engine handle, its edit history, and the pictures on show for it.
import 'dart:ui' as ui;

import 'catalogue.dart';

/// Undo history, as web/src/editor-state.js `historyReducer` keeps it. Changes under one `group`
/// (a slider being dragged) make one step.
class History {
  History(this.present);
  final List<Json> past = [];
  Json present;
  final List<Json> future = [];
  String? group;
}

/// A frame the engine presented on a native layer, and the geometry it was developed for.
class PresentedFrame {
  const PresentedFrame({
    required this.id,
    required this.signature,
    required this.width,
    required this.height,
    this.region,
    this.scale,
  });

  final int id;

  /// The edit the frame shows, so a stale frame is not mistaken for the current one.
  final String signature;
  final int width, height;

  /// For a `detail` frame: the part of the photograph it covers, in the photograph's logical
  /// pixels at `scale`.
  final ui.Rect? region;
  final double? scale;
}

class PhotoDocument {
  PhotoDocument({
    required this.path,
    required this.handle,
    required this.width,
    required this.height,
    required this.history,
    this.identity,
    this.raw = false,
  });

  /// Where it was opened from; a rename in the library follows it.
  String path;
  final int handle;
  final int width, height;
  final String? identity;
  final bool raw;
  final History history;

  String get name => path.split('/').last;
  Json get edit => history.present;

  /// The undeveloped picture the import answered with: on show until the first develop, and the
  /// strip's picture.
  ui.Image? importPicture;

  // ── Native layers ──────────────────────────────────────────────────────────────────────────
  PresentedFrame? preview;
  PresentedFrame? detail;

  // ── Encoded fallback (a host without a presenter) ──────────────────────────────────────────
  ui.Image? previewImage;
  ui.Image? originalImage;
  String? originalKey;
  String? previewSignature;
  int previewEdge = 0;

  // ── Small pictures, developed in the background ────────────────────────────────────────────
  /// Each one stays on show until its successor for a newer edit arrives.
  final filmThumbnails = ThumbnailSet();
  final formatThumbnails = ThumbnailSet();
}

/// Pictures keyed by what they show, and which of them are current for `signature`.
class ThumbnailSet {
  final Map<String, ui.Image> images = {};
  final Set<String> fresh = {};
  String? signature;

  /// Starts a new generation: the old pictures stay until replaced.
  void renew(String next) {
    if (signature == next) return;
    signature = next;
    fresh.clear();
  }

  ui.Image? operator [](String key) => images[key];
}
