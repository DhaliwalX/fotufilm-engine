// The plug-ins for other editors the engine's platform installs (DaVinci Resolve and Final Cut Pro
// on the Mac), as the Mac app's Plugins menu and launch offer handle them. The state is read when
// the editor opens, when its window comes back to the front and after every install, since a
// plug-in can be installed or removed behind the editor's back.
import 'package:flutter/foundation.dart';

import 'app_dialogs.dart';
import 'editor.dart';

/// The plug-ins worth offering at launch: carried by this build, not installed as this build's,
/// and for an editor that is on this computer.
List<Json> pluginsToOffer(List<Json>? list) => [
      for (final p in list ?? const <Json>[])
        if (p['bundledVersion'] != null &&
            p['hostInstalled'] == true &&
            (p['state'] == 'notInstalled' || p['state'] == 'outdated'))
          p,
    ];

/// The launch offer, unless this build's was declined.
class PluginOffer {
  const PluginOffer(this.ids, this.version, {required this.updating});
  final List<String> ids;
  final String version;

  /// Whether every plug-in offered is one from another build.
  final bool updating;

  static PluginOffer? of(List<Json>? list, Object? declined) {
    final pending = pluginsToOffer(list);
    if (pending.isEmpty) return null;
    final version = pending.first['bundledVersion'] as String;
    if (declined == version) return null;
    return PluginOffer([for (final p in pending) p['id'] as String], version,
        updating: pending.every((p) => p['state'] == 'outdated'));
  }
}

/// "A", "A and B", "A, B and C".
String joinedNames(List<String> names) => names.length > 1
    ? '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}'
    : names.firstOrNull ?? '';

/// What a plug-in's state reads as, from its `plugins` entry.
String pluginStatusText(Json? status) {
  if (status == null) return 'Checking…';
  String build(Object? version) => version != null ? ' (build $version)' : '';
  switch (status['state']) {
    case 'installed':
      return 'Installed${build(status['installedVersion'])}.';
    case 'outdated':
      return 'Installed from another version of Fotufilm${build(status['installedVersion'])}. '
          'Update to install this version\'s${build(status['bundledVersion'])}.';
    case 'notInstalled':
      return status['hostInstalled'] == true
          ? 'Not installed.'
          : 'Not installed. ${status['name']} is not on this computer; the plug-in can be '
              'installed ahead of it.';
    default:
      return 'This copy of Fotufilm does not contain this plug-in.';
  }
}

/// The install button's label for a plug-in's state.
String installLabel(Json? status) => switch (status?['state']) {
      'outdated' => 'Update',
      'installed' => 'Reinstall',
      _ => 'Install',
    };

/// An install's answer, or why it failed, for the plug-in it was about.
class PluginResult {
  const PluginResult(this.id, {this.message, this.error});
  final String id;
  final String? message, error;
}

class Plugins extends ChangeNotifier {
  Plugins(this.editor);
  final EditorModel editor;

  /// The plug-ins this platform installs, `{id, name}`, named up front.
  List<Json> get catalogue =>
      ((editor.engine?.capabilities['plugins'] as List?) ?? const []).cast<Json>();
  bool get available => catalogue.isNotEmpty;

  /// Each plug-in as this machine has it now; null until read.
  List<Json>? list;

  /// The plug-in being installed.
  String? busy;
  PluginResult? result;
  PluginOffer? offer;
  bool _offered = false;

  Json? status(String id) => list?.where((p) => p['id'] == id).firstOrNull;

  Future<List<Json>?> refresh() async {
    if (!available) return null;
    final answer = await editor.engine!.call('plugins');
    list = ((answer.value as List?) ?? const []).cast<Json>();
    notifyListeners();
    return list;
  }

  Future<void> install(String id) async {
    if (!available) return;
    busy = id;
    result = null;
    notifyListeners();
    try {
      final answer = (await editor.engine!.call('installPlugin', {'id': id})).json;
      if (answer['plugins'] case final List plugins) list = plugins.cast<Json>();
      result = PluginResult(id, message: answer['message'] as String?);
    } catch (e) {
      result = PluginResult(id, error: '$e');
      refresh().ignore();
    } finally {
      busy = null;
      notifyListeners();
    }
  }

  Future<void> reveal(String id) async {
    try {
      await editor.engine!.call('revealPlugin', {'id': id});
    } catch (e) {
      result = PluginResult(id, error: '$e');
      notifyListeners();
    }
  }

  /// At launch: offers this build's plug-ins where they are missing or from another build, unless
  /// this build's offer was declined. Only over an empty editor: a dialog already up is the
  /// person's, not ours to replace.
  Future<void> launch() async {
    if (!available || _offered) return;
    _offered = true;
    try {
      final pending = PluginOffer.of(await refresh(), editor.settings.get('pluginOfferDeclined'));
      if (pending == null || editor.dialogs.open != null) return;
      offer = pending;
      notifyListeners();
      editor.dialogs.request(AppDialog.plugins);
    } catch (_) {}
  }

  /// Declining is remembered against this build: a later build asks again.
  void decline() {
    if (offer != null) editor.settings.set('pluginOfferDeclined', offer!.version);
    offer = null;
    notifyListeners();
  }

  Future<void> acceptOffer() async {
    final ids = offer?.ids;
    if (ids == null) return;
    editor.settings.set('pluginOfferDeclined', null);
    offer = null;
    notifyListeners();
    for (final id in ids) {
      await install(id);
    }
  }

  /// The offer belongs to the dialog it opened; closed any other way, it is left for next launch.
  void dialogClosed() {
    if (offer == null) return;
    offer = null;
    notifyListeners();
  }
}
