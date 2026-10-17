// The window the editor runs in. On macOS the toolbar shares the titlebar, so the toolbar drags
// and zooms the window and leaves room for the traffic lights; photographs opened from the Finder
// arrive here. Elsewhere the system draws the titlebar and these are no-ops.
import 'dart:io';

import 'package:flutter/services.dart';

abstract final class HostWindow {
  static const _channel = MethodChannel('fotufilm/window');

  /// The toolbar is the titlebar (macOS's full-size content view).
  static bool get toolbarIsTitlebar => Platform.isMacOS;

  /// Menus are the system's menu bar, and shortcuts use ⌘ rather than Ctrl.
  static bool get usesMenuBar => Platform.isMacOS;

  static Future<void> startDrag() => _call('startDrag');
  static Future<void> zoom() => _call('zoom');

  /// Photographs the system asked the app to open, and from then on calls `open` as more come.
  /// `arguments` are main's: Linux and Windows runners pass the command line there.
  static Future<List<String>> takeOpenedFiles(Future<void> Function(List<String>) open,
      {List<String> arguments = const []}) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') await open((call.arguments as List).cast<String>());
    });
    final paths = [...arguments.where((a) => !a.startsWith('-'))];
    try {
      paths.addAll(await _channel.invokeListMethod<String>('takeOpenedFiles') ?? const []);
    } on MissingPluginException {
      // No native side on this platform.
    }
    return paths;
  }

  static Future<void> _call(String method) async {
    try {
      await _channel.invokeMethod(method);
    } on MissingPluginException {
      // No native side on this platform.
    }
  }
}
