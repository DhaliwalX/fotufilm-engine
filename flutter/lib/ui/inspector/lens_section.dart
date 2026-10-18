// The Expose panel's Lens: lens correction on or off, the profile it reads (matched from the
// photograph's lens, or one chosen), the engine's note on what it found, the amount and the manual
// corrections, and the imported lens-profile catalogue.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import '../../model/catalogue.dart';
import '../../model/editor.dart';
import '../../model/lens.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';

class LensSection extends StatelessWidget {
  const LensSection({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor.lens,
        builder: (context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final lenses = editor.lens..load();
    final catalogue = editor.catalogue;
    final lens = {...defaultLens, ...((editor.edit['lens'] as Map?) ?? const {})};
    final doc = editor.active;
    if (doc != null) lenses.follow(doc, lens);
    final plan = lenses.plan;
    final correction = catalogue.control('lensCorrection');

    void change(Json next) => editor.change({'lens': next});
    void set(String key, double value) =>
        editor.patch({'lens': {...lens, key: value}}, group: 'lens-$key');

    final amount = catalogue.catalogueSlider('lensAmount', 'Lens');
    final profileID = lens['profileID'] as String?;
    return Section(title: 'Lens', children: [
      SwitchRow(
        label: correction['title'] as String,
        detail: correction['detail'] as String?,
        value: lens['enabled'] == true,
        onChanged: (on) => change({...lens, 'enabled': on}),
      ),
      if (lens['enabled'] == true) ...[
        if (lenses.profiles.isNotEmpty)
          PickerField<String>(
            label: 'Profile',
            value: profileID == null ? 'automatic' : 'profile:$profileID',
            options: [
              const PickerOption('automatic', 'Automatic'),
              for (final p in lenses.profiles)
                PickerOption('profile:${p['id']}', '${p['maker']} ${p['model']}'),
              if (profileID != null && !lenses.profiles.any((p) => p['id'] == profileID))
                PickerOption('profile:$profileID', 'Profile not installed'),
            ],
            onChanged: (id) => change({
              ...lens,
              'profileID': id == 'automatic' ? null : id.substring('profile:'.length),
            }),
          ),
        Note((plan?['note'] as String?)?.isNotEmpty == true
            ? plan!['note'] as String
            : lenses.planError != null
                ? 'Lens correction could not be prepared.'
                : 'Reading lens correction…'),
        if (plan != null && plan['measurement'] != 'none')
          AdjustmentRow(
            key: const ValueKey('lensAmount'),
            label: amount.label,
            detail: amount.detail,
            value: ((lens['amount'] as num?) ?? 1) * 100,
            range: SliderRange(
                min: amount.min * 100, max: amount.max * 100, step: 1, def: amount.def * 100),
            ends: catalogue.sliderEnds('lensAmount'),
            onChanged: (v) => set('amount', v / 100),
            onEnd: editor.endEdit,
          ),
        for (final MapEntry(key: field, value: key) in lensFields.entries)
          _slider(catalogue.catalogueSlider(field, 'Lens'), (lens[key] as num).toDouble(),
              (v) => set(key, v)),
        Align(
          alignment: Alignment.centerLeft,
          child: QuietButton(
            label: 'Reset Lens',
            onPressed: hasLensAdjustments(lens)
                ? () => change({...defaultLens, 'enabled': lens['enabled']})
                : null,
          ),
        ),
        _LensProfileLibrary(lenses: lenses),
        if (lenses.planError != null) Note(lenses.planError!),
      ],
    ]);
  }

  Widget _slider(SliderSpec s, double value, ValueChanged<double> onChanged) => AdjustmentRow(
        key: ValueKey(s.key),
        label: s.label,
        detail: s.detail,
        value: value,
        range: SliderRange(min: s.min, max: s.max, step: s.step, def: s.def),
        ends: editor.catalogue.sliderEnds(s.key),
        onChanged: onChanged,
        onEnd: editor.endEdit,
      );
}

/// Lens Profiles: importing a lens-profile catalogue, and removing what was imported.
class _LensProfileLibrary extends StatefulWidget {
  const _LensProfileLibrary({required this.lenses});
  final LensCorrection lenses;

  @override
  State<_LensProfileLibrary> createState() => _LensProfileLibraryState();
}

class _LensProfileLibraryState extends State<_LensProfileLibrary> {
  bool _busy = false;
  String? _progress, _error;

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final message = await action();
      if (message != null) _progress = message;
    } catch (e) {
      _error = '$e';
      _progress = null;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<String?> _import() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Lens profiles', extensions: ['json']),
    ]);
    if (file == null) return null;
    final count = await widget.lenses.import(file);
    return '$count lens ${count == 1 ? 'profile' : 'profiles'} imported.';
  }

  @override
  Widget build(BuildContext context) {
    final lenses = widget.lenses;
    final count = lenses.profiles.length;
    final error = _error ?? lenses.catalogueError;
    return Section(
      title: 'Lens Profiles${count > 0 ? ' · $count' : ''}',
      initiallyOpen: false,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: QuietButton(
            label: 'Import Lens Profiles…',
            onPressed: _busy ? null : () => _run(_import),
          ),
        ),
        if (count > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: QuietButton(
              label: 'Remove Imported Profiles',
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await lenses.remove();
                        return 'Imported lens profiles removed.';
                      }),
            ),
          ),
        if (_progress != null) Note(_progress!),
        if (error != null)
          Text(error, style: editorText(context, size: TextSizes.label, color: Palette.of(context).muted)),
      ],
    );
  }
}
