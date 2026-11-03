// The Mac app's Settings window: what new photographs start on, how photos export, and the film
// model. Everything here is kept on this device; open photographs keep their own edits. Video's
// settings wait for video in this editor.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import '../../app/strings.dart';
import '../../model/editor.dart';
import '../../model/film_packs.dart';
import '../../model/film_suggestion.dart';
import '../../model/new_photo.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'app_dialogs.dart';

enum SettingsPane { general, output, filmModel }

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.editor, required this.onClose});
  final EditorModel editor;
  final VoidCallback onClose;

  /// The pane a driver or a later opening asks for.
  static SettingsPane pane = SettingsPane.general;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsPane _pane = SettingsDialog.pane;

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    return ListenableBuilder(
      listenable: Listenable.merge(
          [editor, editor.settings, editor.filmPacks, editor.filmSuggestion]),
      builder: (context, _) => AppDialogCard(
        title: AppStrings.tr('Settings'),
        onDismiss: widget.onClose,
        children: [
          SegmentedControl<SettingsPane>(
            items: [
              (SettingsPane.general, AppStrings.tr('General')),
              (SettingsPane.output, AppStrings.tr('Output')),
              (SettingsPane.filmModel, AppStrings.tr('Film Model')),
            ],
            selected: _pane,
            onChanged: (p) => setState(() => _pane = SettingsDialog.pane = p),
          ),
          const SizedBox(height: 8),
          ...switch (_pane) {
            SettingsPane.general => _general(context),
            SettingsPane.output => _output(),
            SettingsPane.filmModel => _filmModel(),
          },
        ],
      ),
    );
  }

  AppSettings get _settings => widget.editor.settings;

  List<PickerOption<String?>> _choices(String field) => [
        for (final c in (widget.editor.catalogue.control(field)['choices'] as List).cast<Json>())
          PickerOption(c['id'] as String, c['label'] as String),
      ];

  // ── General ─────────────────────────────────────────────────────────────────────────────

  List<Widget> _general(BuildContext context) {
    final editor = widget.editor;
    final suggestion = editor.filmSuggestion;
    final learned = suggestion.learned == null || suggestion.learned! > 0;
    return [
      PaneHeading(AppStrings.tr('New Photos')),
      _SettingPicker(
        label: AppStrings.tr('Starting Film'),
        setting: 'startingFilm',
        settings: _settings,
        options: [
          PickerOption(null, AppStrings.tr('Current Film')),
          PickerOption('none', AppStrings.tr('Normal')),
          for (final s in editor.stocks) PickerOption(s['id'] as String, s['name'] as String),
        ],
      ),
      _SettingPicker(
        label: AppStrings.tr('Film Format'),
        setting: 'startingFormat',
        settings: _settings,
        options: [
          PickerOption(null, AppStrings.tr('Match the Film')),
          for (final f in editor.catalogue.filmFormats)
            PickerOption(f['id'] as String, f['name'] as String),
        ],
      ),
      if (suggestion.available) ...[
        _SettingSwitch(label: AppStrings.tr('Suggest a Film Automatically'), setting: 'autoFilm', settings: _settings),
        PaneNote(AppStrings.tr('Suggests a film when you open a photo, based on your previous choices. You can select a different film at any time.')),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: _ForgetButton(suggestion: suggestion, learned: learned),
        ),
      ],
      if (editor.filmPacks.available) _FilmPacksSection(packs: editor.filmPacks),
      if (editor.updates.available) ...[
        PaneHeading(AppStrings.tr('Updates')),
        _SettingSwitch(
            label: AppStrings.tr('Check for Updates Automatically'),
            setting: 'updateChecksAutomatically',
            settings: _settings),
        _SettingSwitch(label: AppStrings.tr('Include Pre-releases'), setting: 'updatePrereleases', settings: _settings),
      ],
      PaneHeading(AppStrings.tr('Reset')),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: PillButton('Reset All Settings',
            variant: ButtonVariant.negative, onPressed: () => _confirmReset(context)),
      ),
      PaneNote(AppStrings.tr('Restores Fotufilm’s original settings. Your photographs and edits are not changed.')),
    ];
  }

  void _confirmReset(BuildContext context) {
    showModal(
      context,
      (close) => AlertCard(
        title: 'Reset All Settings?',
        message: 'This restores Fotufilm’s original settings. Your photos and edits will not change.',
        primary: 'Reset',
        variant: ButtonVariant.negative,
        cancel: 'Cancel',
        onCancel: close,
        onPrimary: () {
          _settings.resetAll();
          close();
        },
      ),
    );
  }

  // ── Output ──────────────────────────────────────────────────────────────────────────────

  List<Widget> _output() {
    final exports =
        ((widget.editor.engine?.capabilities['imageExportTypes'] as List?) ?? const []).isNotEmpty;
    if (!exports) {
      return [
        PaneHeading(AppStrings.tr('Photos')),
        const PaneNote('This engine exports photos in standard dynamic range.'),
        ..._video(),
      ];
    }
    return [
      PaneHeading(AppStrings.tr('Photos')),
      const SizedBox(height: 4),
      _SettingSwitch(label: AppStrings.tr('HDR'), setting: 'photoHDR', settings: _settings),
      const PaneNote('HDR preserves brighter highlights on compatible displays. Choose Standard '
          'for wider compatibility. It applies to HEIC exports of films that deliver HDR, '
          'without a print frame.'),
      _SettingPicker(
        label: AppStrings.tr('Photo Quality'),
        setting: 'photoQuality',
        settings: _settings,
        options: [PickerOption('accurate', AppStrings.tr('Accurate')), PickerOption('fast', AppStrings.tr('Fast'))],
      ),
      PaneNote(AppStrings.tr('Accurate uses exact film curves. Fast uses an approximation to reduce processing time.')),
      ..._video(),
    ];
  }

  /// Video Quality, HDR and Video File Size where the engine's platform offers them, and the
  /// transport's Playback Quality where it plays movies.
  List<Widget> _video() {
    final exporter = widget.editor.exporter;
    final playable = widget.editor.engine?.capabilities['video'] == true;
    final hdr = exporter.videoTypes.any((t) => t['hdr'] == true);
    final bitrates = exporter.videoBitrates;
    if (!playable) return const [];
    return [
      PaneHeading(AppStrings.tr('Video')),
      _SettingPicker(
        label: AppStrings.tr('Playback Quality'),
        setting: 'videoPlaybackQuality',
        settings: _settings,
        options: [for (final (id, name, _) in playbackQualities) PickerOption(id, name)],
      ),
      const PaneNote(playbackQualityHelp),
      if (exporter.videoProcessingOffered) ...[
        _SettingPicker(
          label: AppStrings.tr('Video Quality'),
          setting: 'videoProcessing',
          settings: _settings,
          options: [PickerOption('full', AppStrings.tr('Full')), PickerOption('fast', AppStrings.tr('Fast'))],
        ),
        const PaneNote('Video quality sets the processing resolution. Full uses the source '
            'resolution; Fast processes at up to 1080p.'),
      ],
      if (hdr) ...[
        _SettingSwitch(label: AppStrings.tr('HDR'), setting: 'videoHDR', settings: _settings),
        const PaneNote('HEVC and ProRes movies of films that deliver HDR are written as HLG; '
            'H.264 stays standard.'),
      ],
      if (bitrates.isNotEmpty) ...[
        _SettingPicker(
          label: AppStrings.tr('Video File Size'),
          setting: 'videoBitrate',
          settings: _settings,
          options: [
            for (final b in bitrates) PickerOption(b['id'] as String, b['label'] as String),
          ],
        ),
        const PaneNote('Automatic lets the encoder choose. ProRes keeps its own rate.'),
      ],
    ];
  }

  // ── Film Model ──────────────────────────────────────────────────────────────────────────

  /// The Mac app reads halation as a photo develops, so those settings reach the open photo.
  bool get _modelled => widget.editor.active != null && widget.editor.edit['stock'] != null;

  List<Widget> _filmModel() {
    final editor = widget.editor;
    String title(String field) => editor.catalogue.control(field)['title'] as String;
    return [
      const PaneHeading('Grain'),
      _SettingPicker(
        label: title('grainModel'),
        setting: 'grainModel',
        settings: _settings,
        options: _choices('grainModel'),
      ),
      const PaneNote('Standard uses fast calibrated RMS noise, and Film lays the stock’s crystals '
          'at fixed places on the emulsion.'),
      const PaneHeading('Halation'),
      _SettingPicker(
        label: title('halationModel'),
        setting: 'halationModel',
        settings: _settings,
        options: _choices('halationModel'),
        onSet: (model) {
          if (_modelled) editor.change({'halationModel': model});
        },
      ),
      _SettingSwitch(
        label: title('estimatedHalation'),
        setting: 'estimatedHalation',
        settings: _settings,
        onSet: (on) {
          if (_modelled) editor.setProfile('estimatedHalation', on, grouped: false);
        },
      ),
      const PaneNote('Layered Transport simulates light moving through the film layers. In the '
          'browser, films with donor layers use Legacy. Estimated Halation Shape only affects '
          'Legacy.'),
      const PaneHeading('Color Separation'),
      _SettingSlider(label: title('couplerReach'), setting: 'couplerReach', settings: _settings),
      _SettingSlider(
          label: 'Red–Green', setting: 'couplerRedGreen', follows: 'couplerReach', settings: _settings),
      _SettingSlider(
          label: 'Green–Blue', setting: 'couplerGreenBlue', follows: 'couplerReach', settings: _settings),
      _SettingSlider(label: title('couplerSelf'), setting: 'couplerSelf', settings: _settings),
      const PaneNote('Separation sets how strongly neighboring film layers affect each other '
          'during development, for both color pairs together. Red–Green and Green–Blue adjust '
          'each pair separately. Edge Contrast controls sharpening caused by development.'),
      const PaneNote('Halation settings also change the open photo. The others apply to photos '
          'you open from now on; each open photo keeps its own.'),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: PillButton(
          'Restore Film Model',
          variant: ButtonVariant.negative,
          onPressed: filmModelAdjusted(_settings)
              ? () {
                  for (final key in filmModelSettings) {
                    _settings.set(key, AppSettings.defaults[key]);
                  }
                }
              : null,
        ),
      ),
    ];
  }
}

/// A picker for a setting; null is its default choice. `onSet` also runs with each new value, for
/// a setting the open photo follows.
class _SettingPicker extends StatelessWidget {
  const _SettingPicker({
    required this.label,
    required this.setting,
    required this.settings,
    required this.options,
    this.onSet,
  });

  final String label, setting;
  final AppSettings settings;
  final List<PickerOption<String?>> options;
  final ValueChanged<String?>? onSet;

  @override
  Widget build(BuildContext context) {
    final value = settings.get<Object>(setting);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(label, style: editorText(context))),
        const SizedBox(width: 12),
        SizedBox(
          width: 220,
          child: PickerField<String?>(
            value: value is String ? value : null,
            options: options,
            onChanged: (next) {
              settings.set(setting, next);
              onSet?.call(next);
            },
          ),
        ),
      ]),
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch(
      {required this.label, required this.setting, required this.settings, this.onSet});
  final String label, setting;
  final AppSettings settings;
  final ValueChanged<bool>? onSet;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SwitchRow(
          label: label,
          value: settings.get(setting) == true,
          onChanged: (next) {
            settings.set(setting, next);
            onSet?.call(next);
          },
        ),
      );
}

/// A slider from 0 to 3 in tenths. `follows`: the setting shown while this one has never been set
/// on its own.
class _SettingSlider extends StatelessWidget {
  const _SettingSlider(
      {required this.label, required this.setting, required this.settings, this.follows});
  final String label, setting;
  final String? follows;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final own = settings.get<num>(setting);
    final followed = settings.get<num>(follows ?? setting);
    final value = (own ?? followed ?? 1).toDouble();
    final rest = (AppSettings.defaults[setting] as num?) ?? followed ?? 1;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: AdjustmentRow(
        label: label,
        value: value,
        range: SliderRange(min: 0, max: 3, step: .1, def: rest.toDouble()),
        onChanged: (next) => settings.set(setting, (next * 10).round() / 10),
      ),
    );
  }
}

/// Reset Film Suggestions: greyed with nothing learned, as the Mac app's is.
class _ForgetButton extends StatefulWidget {
  const _ForgetButton({required this.suggestion, required this.learned});
  final FilmSuggestion suggestion;
  final bool learned;

  @override
  State<_ForgetButton> createState() => _ForgetButtonState();
}

class _ForgetButtonState extends State<_ForgetButton> {
  bool _forgotten = false;

  @override
  void initState() {
    super.initState();
    widget.suggestion.refresh();
  }

  @override
  Widget build(BuildContext context) => PillButton(
        _forgotten ? 'Film Suggestions Reset' : 'Reset Film Suggestions',
        onPressed: _forgotten || !widget.learned
            ? null
            : () => widget.suggestion.forget().then((_) {
                  if (mounted) setState(() => _forgotten = true);
                }).ignore(),
      );
}

/// The community packs installed where this person's films live: add more, or take one away with
/// its films.
class _FilmPacksSection extends StatefulWidget {
  const _FilmPacksSection({required this.packs});
  final FilmPacks packs;

  @override
  State<_FilmPacksSection> createState() => _FilmPacksSectionState();
}

class _FilmPacksSectionState extends State<_FilmPacksSection> {
  String? _notice;
  bool _busy = false;

  FilmPacks get packs => widget.packs;

  @override
  void initState() {
    super.initState();
    // Read afresh each time: another app may have added one since.
    packs.refresh().ignore();
  }

  Future<void> _run(Future<String?> Function() work, String failure) async {
    setState(() => _busy = true);
    String? notice;
    try {
      notice = await work();
    } catch (e) {
      notice = '$failure — $e';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _notice = notice;
      });
    }
  }

  Future<void> _import() => _run(() async {
        final files = await openFiles(acceptedTypeGroups: const [
          XTypeGroup(label: 'Film packs', extensions: [filmPackExtension]),
        ]);
        if (files.isEmpty) return _notice;
        final notice = PackNotice.of(
            await packs.importPaths([for (final f in files) f.path], quiet: true));
        return '${notice.title} — ${notice.message}';
      }, 'Pack not added');

  @override
  Widget build(BuildContext context) {
    final installed = packs.installed ?? const [];
    final disabled = _busy || packs.editor.exporting || packs.editor.exporter.busy;
    final muted = editorText(context, size: TextSizes.label, color: Palette.of(context).muted);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const PaneHeading('Film Packs'),
      if (installed.isEmpty)
        const PaneNote('No film packs are installed.')
      else
        for (final pack in installed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(pack['version'] != null ? '${pack['name']} v${pack['version']}' : '${pack['name']}'),
                  Text(
                    pack['problem'] as String? ??
                        ((pack['films'] as List?) ?? const []).join(', '),
                    style: muted,
                  ),
                ]),
              ),
              const SizedBox(width: 12),
              PillButton('Remove',
                  onPressed: disabled
                      ? null
                      : () => _run(() async {
                            await packs.remove(pack['packID'] as String);
                            return null;
                          }, 'Pack not removed')),
            ]),
          ),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: PillButton('Import Film Pack…', onPressed: disabled ? null : _import),
      ),
      if (_notice != null) PaneNote(_notice!),
    ]);
  }
}
