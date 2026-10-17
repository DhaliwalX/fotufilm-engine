// The dialogs of Copy Settings and presets: Copy Settings… and Save Preset… choose the sections
// that travel (web/src/editor/SettingsSectionsDialog.jsx), Manage Presets… applies, renames,
// exports and deletes presets and imports look files (PresetsDialog.jsx). Each follows the editor
// while it is open.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/presets.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'dialogs.dart';

AnchoredOverlay showCopySettingsDialog(BuildContext context, EditorModel editor) => showModal(
    context, (close) => _SectionsDialog(editor: editor, preset: false, onClose: close));

AnchoredOverlay showSavePresetDialog(BuildContext context, EditorModel editor) => showModal(
    context, (close) => _SectionsDialog(editor: editor, preset: true, onClose: close));

AnchoredOverlay showPresetsDialog(BuildContext context, EditorModel editor) =>
    showModal(context, (close) => _PresetsDialog(editor: editor, onClose: close));

/// Import Looks…: the presets added, then the presets to see them, unless something was not read.
Future<void> importLooks(BuildContext context, EditorModel editor) async {
  final added = await editor.presets.importChosen();
  if (added > 0 && editor.error == null && context.mounted) showPresetsDialog(context, editor);
}

// ── Copy Settings… and Save Preset… ──────────────────────────────────────────────────────────

class _SectionsDialog extends StatefulWidget {
  const _SectionsDialog({required this.editor, required this.preset, required this.onClose});
  final EditorModel editor;
  final bool preset;
  final VoidCallback onClose;

  @override
  State<_SectionsDialog> createState() => _SectionsDialogState();
}

class _SectionsDialogState extends State<_SectionsDialog> {
  late List<String> _sections = [...widget.editor.presets.sections];
  final _name = TextEditingController();
  final _focus = FocusNode();

  Presets get presets => widget.editor.presets;

  @override
  void initState() {
    super.initState();
    if (widget.preset) WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _ready => _sections.isNotEmpty && (!widget.preset || _name.text.trim().isNotEmpty);

  void _confirm() {
    if (!_ready) return;
    if (widget.preset) {
      presets.save(_name.text.trim(), _sections);
    } else {
      presets.copy(_sections);
    }
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final groups = <String, List<SettingsSection>>{};
    for (final s in presets.allSections) {
      (groups[s.group] ??= []).add(s);
    }
    final replaces = widget.preset && presets.list.any((p) => p.name == _name.text.trim());
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
      child: DialogCard(
        title: widget.preset ? 'Save Preset' : 'Copy Settings',
        width: 520,
        actions: [
          PillButton('Check All',
              onPressed: () => setState(() => _sections = [for (final s in presets.allSections) s.id])),
          PillButton('Check None', onPressed: () => setState(() => _sections = [])),
          const Spacer(),
          PillButton('Cancel', onPressed: widget.onClose),
          PillButton(widget.preset ? 'Save' : 'Copy',
              variant: ButtonVariant.accent, onPressed: _ready ? _confirm : null),
        ],
        children: [
          if (widget.preset) ...[
            const FieldLabel('Name'),
            const SizedBox(height: 3),
            NameField(
              controller: _name,
              focusNode: _focus,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _confirm(),
            ),
            if (replaces) ...[
              const SizedBox(height: 4),
              Text('Replaces the preset of this name.',
                  style: editorText(context, size: TextSizes.label, color: palette.muted)),
            ],
            const SizedBox(height: 16),
          ],
          // The inspector's sections under their tabs' titles: Film, Lens, Light & Color, Print,
          // Frame.
          Wrap(spacing: 24, runSpacing: 16, children: [
            for (final group in groups.values)
              SizedBox(
                width: 140,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(group.first.groupTitle,
                      style: editorText(context,
                          size: TextSizes.label, color: palette.text.withValues(alpha: .75))),
                  const SizedBox(height: 4),
                  for (final section in group)
                    CheckboxRow(
                      label: section.title,
                      value: _sections.contains(section.id),
                      onChanged: (on) => setState(() => _sections = on
                          ? [..._sections, section.id]
                          : [for (final id in _sections) if (id != section.id) id]),
                    ),
                ]),
              ),
          ]),
        ],
      ),
    );
  }
}

/// A filled single-line text field (Spectrum's TextField at size S).
class NameField extends StatelessWidget {
  const NameField({
    super.key,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged, onSubmitted;

  @override
  Widget build(BuildContext context) => Container(
        height: Metrics.control + 4,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
            color: Palette.of(context).gray100, borderRadius: BorderRadius.circular(Metrics.radius)),
        child: EditableField(
          controller: controller,
          focusNode: focusNode,
          style: editorText(context),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      );
}

// ── Manage Presets… ──────────────────────────────────────────────────────────────────────────

class _PresetsDialog extends StatefulWidget {
  const _PresetsDialog({required this.editor, required this.onClose});
  final EditorModel editor;
  final VoidCallback onClose;

  @override
  State<_PresetsDialog> createState() => _PresetsDialogState();
}

class _PresetsDialogState extends State<_PresetsDialog> {
  /// The preset asked to be deleted, and the one being renamed.
  Preset? _doomed;
  String? _renaming;
  final _name = TextEditingController();
  final _focus = FocusNode();

  EditorModel get editor => widget.editor;

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _rename(Preset preset) {
    setState(() => _renaming = preset.id);
    _name.text = preset.name;
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _renamed() {
    final id = _renaming;
    if (id != null && _name.text.trim().isNotEmpty) editor.presets.rename(id, _name.text);
    setState(() => _renaming = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor,
        builder: (context, _) => CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
          child: _doomed == null ? _list(context) : _confirmDelete(context, _doomed!),
        ),
      );

  Widget _confirmDelete(BuildContext context, Preset preset) => DialogCard(
        title: 'Delete “${preset.name}”?',
        width: 360,
        actions: [
          PillButton('Cancel', onPressed: () => setState(() => _doomed = null)),
          PillButton('Delete', variant: ButtonVariant.negative, onPressed: () {
            editor.presets.delete(preset.id);
            setState(() => _doomed = null);
          }),
        ],
        children: const [],
      );

  Widget _list(BuildContext context) {
    final presets = editor.presets;
    final usable = editor.active != null && !editor.exporting;
    return DialogCard(
      title: 'Presets',
      actions: [
        PillButton('Import Looks…', onPressed: () => importLooks(context, editor)),
        PillButton('Export All…',
            onPressed: presets.list.isEmpty
                ? null
                : () => presets.export([for (final p in presets.list) p.id])),
        const Spacer(),
        PillButton('Done', variant: ButtonVariant.accent, onPressed: widget.onClose),
      ],
      children: [
        if (presets.list.isEmpty) const Note('No presets yet.'),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(children: [
              for (final preset in presets.list)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(
                      child: _renaming == preset.id
                          ? NameField(
                              controller: _name, focusNode: _focus, onSubmitted: (_) => _renamed())
                          : Text(preset.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    if (_renaming == preset.id)
                      PillButton('Rename', variant: ButtonVariant.accent, onPressed: _renamed)
                    else
                      PillButton('Apply',
                          onPressed: usable
                              ? () {
                                  presets.applyPreset(preset.id);
                                  widget.onClose();
                                }
                              : null),
                    const SizedBox(width: 4),
                    QuietButton(
                        icon: 'edited', tooltip: 'Rename', onPressed: () => _rename(preset)),
                    QuietButton(
                        icon: 'export',
                        tooltip: 'Export as a Look File…',
                        onPressed: () => presets.export([preset.id])),
                    QuietButton(
                        icon: 'delete',
                        tooltip: 'Delete',
                        onPressed: () => setState(() => _doomed = preset)),
                  ]),
                ),
            ]),
          ),
        ),
      ],
    );
  }
}
