// The macOS menu bar: the menus' items go to the native side when they change (a plug-in list
// arriving), and with every change of the editor what applies, what is ticked and what the changing
// items are called. The native side (MainFlutterWindow.swift `MainMenu`) builds NSMenus from them,
// ticks and greys their items as they validate, and sends back the command chosen.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/editor.dart';
import '../ui/kit/popover.dart' show openModals;
import 'commands.dart';
import 'host_window.dart';

class NativeMenuBar extends StatefulWidget {
  const NativeMenuBar({super.key, required this.commands, required this.child});
  final EditorCommands commands;
  final Widget child;

  @override
  State<NativeMenuBar> createState() => _NativeMenuBarState();
}

class _NativeMenuBarState extends State<NativeMenuBar> {
  static const _channel = MethodChannel('fotufilm/menu');
  late Listenable _sources;
  String? _menus, _state;
  bool _scheduled = false;

  EditorModel get editor => widget.commands.editor;

  @override
  void initState() {
    super.initState();
    _sources = _listen();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'command') widget.commands.run(call.arguments as String);
    });
    _schedule();
  }

  /// Everything the menus read: the editor and its services, the settings the items tick, the
  /// dialogs that cover the photo and the focus a text field may take.
  Listenable _listen() {
    final e = editor;
    final sources = Listenable.merge([
      e, e.library, e.layout, e.plugins, e.filmSuggestion, e.settings, e.updates, e.dialogs, e.video,
      openModals, FocusManager.instance,
    ]);
    sources.addListener(_schedule);
    return sources;
  }

  @override
  void didUpdateWidget(NativeMenuBar old) {
    super.didUpdateWidget(old);
    _schedule();
  }

  @override
  void dispose() {
    _sources.removeListener(_schedule);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// Once a frame at most, after the change has settled.
  void _schedule() {
    if (_scheduled || !HostWindow.usesMenuBar) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _send();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _send() {
    final commands = widget.commands;
    final menus = jsonEncode([for (final menu in commands.menus) menu.toJson()]);
    if (menus != _menus) {
      _menus = menus;
      _call('setMenus', menus);
    }
    final state = jsonEncode(commands.state().toJson());
    if (state != _state) {
      _state = state;
      _call('setState', state);
    }
  }

  static Future<void> _call(String method, String json) async {
    try {
      await _channel.invokeMethod(method, json);
    } on MissingPluginException {
      // No native menu on this platform.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
