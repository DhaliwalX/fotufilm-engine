// How far the engine has come at launch (web/src/editor/useRendererLifecycle.js, the native
// backend's `prepare` reports), for the startup progress card over the empty viewer.

class StartupState {
  const StartupState(this.value, this.label, {this.done = false});
  final double value;
  final String label;
  final bool done;

  static const initial = StartupState(0, 'Loading image engine');
  static const connecting = StartupState(10, 'Connecting to native Halide/Metal');
  static const loadingFilms = StartupState(70, 'Loading native films');
  static const ready = StartupState(100, 'Ready', done: true);
  static const failed = StartupState(100, 'Image engine unavailable', done: true);
}
