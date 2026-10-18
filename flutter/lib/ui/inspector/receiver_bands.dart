// The Print panel's receiver bands: beside the output medium, a button that opens the peaks of the
// three bands Digital Reference reads a colour film through, typed in nm, with the sets saved on
// this device and the bands new photographs start on.
import 'package:flutter/widgets.dart';

import '../../model/band_sets.dart';
import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import '../workspace/dialogs.dart';

/// The output medium's picker, and where the medium reads through bands, their settings.
class MediumRow extends StatefulWidget {
  const MediumRow({super.key, required this.editor, required this.picker, required this.offersBands});
  final EditorModel editor;
  final Widget picker;
  final bool offersBands;

  @override
  State<MediumRow> createState() => _MediumRowState();
}

class _MediumRowState extends State<MediumRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(child: widget.picker),
        if (widget.offersBands) ...[
          const SizedBox(width: 4),
          HoverTip(
            message: 'Receiver bands',
            child: _GlyphButton(
              label: 'Receiver bands',
              expanded: _open,
              glyph: 'fotu.ui.settings',
              color: _open ? palette.accent : palette.muted,
              onPressed: () => setState(() => _open = !_open),
            ),
          ),
        ],
      ]),
      if (widget.offersBands && _open) ...[
        const SizedBox(height: Metrics.controlGap - 8),
        ReceiverBands(editor: widget.editor),
      ],
    ]);
  }
}

class _GlyphButton extends StatefulWidget {
  const _GlyphButton(
      {required this.label, this.expanded, required this.glyph, required this.color, required this.onPressed});
  final String label;
  final bool? expanded;
  final String glyph;
  final Color color;
  final VoidCallback onPressed;

  @override
  State<_GlyphButton> createState() => _GlyphButtonState();
}

class _GlyphButtonState extends State<_GlyphButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return tinted(
      onTap: widget.onPressed,
      label: widget.label,
      expanded: widget.expanded,
      child: Container(
        width: Metrics.control,
        height: Metrics.control,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: pressed ? palette.pressed : hovered ? palette.hover : null,
          borderRadius: BorderRadius.circular(Metrics.radius),
        ),
        child: Glyph(widget.glyph, size: 18, color: widget.color),
      ),
    );
  }
}

class ReceiverBands extends StatelessWidget {
  const ReceiverBands({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor.settings,
        builder: (context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final palette = Palette.of(context);
    final bands = editor.bandSets;
    final sets = bands.sets;
    final profile = editor.edit['profile'] as Map;
    final current = editBands(profile, bands.paper);
    final moved = bandFields.any((f) => profile[f] != null);
    final saved = sets.where((s) => sameBands(s, current)).firstOrNull;
    void apply(Map? set) => editor.change({'profile': withBands(profile, set)});
    final controls = bands.controls;
    final rows = <Widget>[
      if (sets.isNotEmpty)
        PickerField<String?>(
          label: 'Saved Bands',
          value: saved?['name'] as String?,
          placeholder: 'Unsaved',
          options: [for (final s in sets) PickerOption(s['name'] as String, s['name'] as String)],
          onChanged: (name) => apply(sets.firstWhere((s) => s['name'] == name)),
        ),
      for (var i = 0; i < 3; i++)
        Row(children: [
          Expanded(child: FieldLabel(controls[i]['title'] as String, detail: controls[i]['detail'] as String?)),
          NumberBox(
            value: (current[bandKeys[i]] as num).toDouble(),
            onSubmitted: (v) {
              final scale = controls[i]['scale'] as Map;
              final next = v.round().clamp((scale['min'] as num).round(), (scale['max'] as num).round());
              editor.setProfile(bandFields[i], next, grouped: false);
            },
          ),
          const SizedBox(width: 4),
          Text('nm', style: editorText(context, size: TextSizes.label)),
        ]),
      SwitchRow(
        label: 'Use for New Photos',
        value: sameBands(bands.starting, current),
        onChanged: (on) => bands.starting = on ? current : null,
      ),
      Wrap(spacing: 6, runSpacing: 6, children: [
        PillButton('Save Bands…', onPressed: () => showBandSetDialog(context, editor)),
        if (saved != null)
          PillButton('Delete Set', onPressed: () => bands.delete(saved['name'] as String)),
        PillButton('Reset Bands', onPressed: moved ? () => apply(null) : null),
      ]),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: palette.page, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          rows[i],
        ],
      ]),
    );
  }
}

// ── Save Bands… ───────────────────────────────────────────────────────────────────────────────

void showBandSetDialog(BuildContext context, EditorModel editor) =>
    showModal(context, (close) => _BandSetDialog(editor: editor, onClose: close));

class _BandSetDialog extends StatefulWidget {
  const _BandSetDialog({required this.editor, required this.onClose});
  final EditorModel editor;
  final VoidCallback onClose;

  @override
  State<_BandSetDialog> createState() => _BandSetDialogState();
}

class _BandSetDialogState extends State<_BandSetDialog> {
  final _name = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final bands = widget.editor.bandSets;
    bands.save(name, editBands(widget.editor.edit['profile'] as Map, bands.paper));
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final bands = widget.editor.bandSets;
    final current = editBands(widget.editor.edit['profile'] as Map, bands.paper);
    final name = _name.text.trim();
    final replaces = bands.sets.any((s) => s['name'] == name);
    return DialogCard(
      title: 'Save Bands',
      width: 360,
      actions: [
        PillButton('Cancel', onPressed: widget.onClose),
        PillButton('Save', variant: ButtonVariant.accent, onPressed: name.isEmpty ? null : _save),
      ],
      children: [
        FieldLabel('Name'),
        const SizedBox(height: 3),
        Container(
          height: Metrics.control + 4,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(color: palette.fieldFill, borderRadius: BorderRadius.circular(Metrics.radius)),
          child: EditableField(
            controller: _name,
            focusNode: _focus,
            style: editorText(context),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(height: 4),
        Note(replaces
            ? 'Replaces the set of this name.'
            : '${current['red']} / ${current['green']} / ${current['blue']} nm'),
      ],
    );
  }
}
