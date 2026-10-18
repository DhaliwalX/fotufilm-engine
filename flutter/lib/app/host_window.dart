// The window the editor runs in. On macOS the toolbar shares the titlebar, so the toolbar drags
// and zooms the window and leaves room for the traffic lights; photographs opened from the Finder
// arrive here. Elsewhere the system draws the titlebar, and in a browser the page is the window;
// there these are no-ops.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class HostWindow {
  static const _channel = MethodChannel('fotufilm/window');

  static bool get _macApp => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// The toolbar is the titlebar (macOS's full-size content view).
  static bool get toolbarIsTitlebar => _macApp;

  /// Commands are the system's menu bar.
  static bool get usesMenuBar => _macApp;

  /// Shortcuts use ⌘ rather than Ctrl: on a Mac, in the app or in a browser.
  static bool get commandKeyIsMeta => defaultTargetPlatform == TargetPlatform.macOS;

  static Future<void> startDrag() => _call('startDrag');
  static Future<void> zoom() => _call('zoom');

  /// Names the window (Window menu, Mission Control, the Dock), as useDocumentTitle.js does.
  static Future<void> setTitle(String title) => _call('setTitle', title);

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

  /// Files are on a disk the system can open and show; in a browser an export is a download.
  static bool get showsFiles => !kIsWeb;

  /// What showing a file in the system's file manager is called (the CEF hosts' `reveal`).
  static String get revealLabel =>
      defaultTargetPlatform == TargetPlatform.macOS ? 'Show in Finder' : 'Show in Folder';

  /// Where the file manager is, for a plug-in's Show… command.
  static String get fileManager =>
      defaultTargetPlatform == TargetPlatform.macOS ? 'in Finder' : 'in Folder';

  /// Shows files in the Finder (the CEF shell's `revealLibraryFiles`).
  static Future<void> reveal(List<String> paths) => _call('reveal', paths);

  /// Opens a file in the app the system chooses for it (the CEF shell's `openExport`).
  static Future<bool> openFile(String path) async => await _call('openFile', path) == true;

  /// Opens a web address in the browser.
  static Future<bool> openUrl(String url) async => await _call('openURL', url) == true;

  /// File › Use Sample Photo's picture, the CEF app's generated chart in the app's resources.
  static Future<String?> samplePhoto() async => await _call('samplePhoto') as String?;

  /// Photographs opened from the Open panel join File › Open Recent, as the CEF host's do.
  static Future<void> noteRecent(List<String> paths) => _call('noteRecent', paths);

  /// Moves files to the Trash; answers the paths that went.
  static Future<List<String>> trash(List<String> paths) async =>
      ((await _call('trash', paths)) as List?)?.cast<String>() ?? const [];

  static Future<Object?> _call(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod(method, arguments);
    } on MissingPluginException {
      // No native side on this platform.
      return null;
    }
  }
}
