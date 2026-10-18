// Check for Updates, as the Mac app's UpdateCheck runs it: the menu command always answers; the
// automatic check runs shortly after launch and then daily, and says something only when there is a
// release this person has not skipped. The engine reads the feed and downloads, verifies and opens
// the installer (`updateCheck`, `updateStatus`, `updateInstall`, `updateCancel`, `updateNotes`);
// this paces it and says what happened. Include Pre-releases widens every check to releases
// published before they are final.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_dialogs.dart';
import 'editor.dart';

/// A byte count as the Mac's file-size formatter reads it: "12.3 MB".
String formatBytes(num? bytes) {
  if (bytes == null || bytes <= 0) return 'Zero KB';
  const units = ['bytes', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${unit >= 2 ? value.toStringAsFixed(1) : value.round()} ${units[unit]}';
}

/// What the update dialog shows: an offer, a download, or a notice.
sealed class UpdateState {
  const UpdateState();
}

class UpdateAvailable extends UpdateState {
  const UpdateAvailable({
    required this.version,
    required this.release,
    required this.current,
    this.notes,
    required this.allowSkip,
  });
  final String version;
  final String? release, current, notes;

  /// Skip This Version is offered to an automatic check's answer only.
  final bool allowSkip;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.version, this.bytes, this.total);
  final String version;
  final num bytes, total;
}

class UpdateNotice extends UpdateState {
  const UpdateNotice(this.title, this.message, {this.warning = false});
  final String title, message;
  final bool warning;
}

/// What a finished check says, in the Mac app's alerts; null when an automatic one says nothing.
UpdateState? checkOutcome(Json answer, {required bool manual, Object? skipped}) {
  final state = answer['state'];
  final current = answer['current'] as String?;
  if (state == 'available') {
    if (!manual && answer['release'] == skipped) return null;
    final version = answer['version'] as String? ?? '';
    return UpdateAvailable(
      // A pre-release often keeps the running marketing version; its build tells them apart.
      version: current != null && current.startsWith('$version ')
          ? answer['release'] as String? ?? version
          : version,
      release: answer['release'] as String?,
      current: current,
      notes: answer['notes'] as String?,
      allowSkip: !manual,
    );
  }
  if (!manual) return null;
  if (state == 'current') {
    return UpdateNotice("You're up to date", 'Fotufilm $current is the newest release.');
  }
  return UpdateNotice('Fotufilm could not check for updates',
      answer['message'] as String? ?? 'The update feed could not be reached.',
      warning: true);
}

class Updates extends ChangeNotifier {
  Updates(this.editor);
  final EditorModel editor;

  static const _day = Duration(days: 1);
  static const _launchDelay = Duration(seconds: 5);
  static const _poll = Duration(milliseconds: 200);

  bool get available => editor.engine?.capabilities['updates'] == true;

  /// What the update dialog shows.
  UpdateState? update;
  bool _running = false;
  Timer? _launch, _hourly;
  bool _prereleases = false;

  AppSettings get _settings => editor.settings;

  Future<Json> _call(String method, [Json params = const {}]) async =>
      (await editor.engine!.call(method, params)).json;

  void _show(UpdateState? next) {
    update = next;
    notifyListeners();
    if (next != null) editor.dialogs.request(AppDialog.update);
  }

  /// Shortly after launch, then whenever a day has passed since the feed last answered; and at
  /// once when Include Pre-releases is turned on, rather than up to a day later.
  void launch() {
    if (!available) return;
    bool due() {
      if (_settings.get('updateChecksAutomatically') == false) return false;
      final last = _settings.get<num>('updateLastCheck') ?? 0;
      return DateTime.now().millisecondsSinceEpoch - last >= _day.inMilliseconds;
    }

    void run() {
      if (due()) check(manual: false);
    }

    _launch = Timer(_launchDelay, run);
    _hourly = Timer.periodic(const Duration(hours: 1), (_) => run());
    _prereleases = _settings.get('updatePrereleases') == true;
    _settings.addListener(_settingsChanged);
  }

  void _settingsChanged() {
    final prereleases = _settings.get('updatePrereleases') == true;
    if (prereleases && !_prereleases && _settings.get('updateChecksAutomatically') != false) {
      check(manual: false);
    }
    _prereleases = prereleases;
  }

  /// Check for Updates…: `manual` always answers.
  Future<void> check({bool manual = true}) async {
    if (!available || _running) return;
    _running = true;
    try {
      var answer =
          await _call('updateCheck', {'prereleases': _settings.get('updatePrereleases') == true});
      while (answer['state'] == 'checking') {
        await Future<void>.delayed(_poll);
        answer = await _call('updateStatus');
      }
      if (answer['state'] == 'current' || answer['state'] == 'available') {
        _settings.set('updateLastCheck', DateTime.now().millisecondsSinceEpoch);
      }
      final outcome =
          checkOutcome(answer, manual: manual, skipped: _settings.get('updateSkipped'));
      if (outcome != null) _show(outcome);
    } catch (e) {
      if (manual) _show(checkOutcome({'state': 'failed', 'message': '$e'}, manual: true));
    } finally {
      _running = false;
    }
  }

  /// Download and Install…: the installer opens once the download matches its checksum.
  Future<void> install() async {
    final offer = update;
    if (offer is! UpdateAvailable) return;
    _show(UpdateDownloading(offer.version, 0, 0));
    try {
      var answer = await _call('updateInstall');
      while (answer['state'] == 'downloading') {
        _show(UpdateDownloading(
            offer.version, answer['bytes'] as num? ?? 0, answer['total'] as num? ?? 0));
        await Future<void>.delayed(_poll);
        answer = await _call('updateStatus');
      }
      if (answer['state'] == 'opened') {
        update = null;
        editor.dialogs.close(AppDialog.update);
        notifyListeners();
      } else if (answer['state'] == 'downloadFailed') {
        _show(UpdateNotice(
          answer['verify'] == true
              ? 'The update could not be verified.'
              : 'The update could not be downloaded.',
          answer['message'] as String? ?? '',
          warning: true,
        ));
      } else {
        // Cancelled: the offer stands again.
        _show(offer);
      }
    } catch (e) {
      _show(UpdateNotice('The update could not be downloaded.', '$e', warning: true));
    }
  }

  Future<void> cancel() async {
    try {
      await _call('updateCancel');
    } catch (_) {}
  }

  /// Skip This Version: an automatic check stays quiet about this release.
  void skip() {
    final offer = update;
    if (offer is UpdateAvailable && offer.release != null) {
      _settings.set('updateSkipped', offer.release);
    }
    editor.dialogs.close(AppDialog.update);
  }

  Future<void> openNotes() async {
    try {
      await _call('updateNotes');
    } catch (_) {}
  }

  @override
  void dispose() {
    _launch?.cancel();
    _hourly?.cancel();
    _settings.removeListener(_settingsChanged);
    super.dispose();
  }
}
