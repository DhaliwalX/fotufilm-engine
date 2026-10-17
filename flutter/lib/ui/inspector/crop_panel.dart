// The Crop tool's panel (web/src/CropControls.jsx, editor/CropInspector.jsx): orientation, the
// crop's shape, aspect and straightening with its size, perspective, and Reset and Done.
import 'package:flutter/widgets.dart';

import '../kit/kit.dart';
import '../theme/theme.dart';
import 'controls.dart';

List<Widget> cropPanel(InspectorControls c) {
  final editor = c.editor;
  final crop = editor.crop;
  final size = crop.cropSize;
  return [
    Section(title: 'Orientation', children: [
      Row(children: [
        Expanded(child: _ActionButton(icon: 'rotate', label: 'Rotate Left', onPressed: crop.rotateLeft)),
        const SizedBox(width: 8),
        Expanded(child: _ActionButton(icon: 'flip', label: 'Flip', onPressed: crop.flip)),
      ]),
    ]),
    Section(title: 'Crop', children: [
      _ToggleButton(
        label: 'Four-Corner Crop',
        selected: crop.shape == 'corners',
        onPressed: crop.fourCorners,
      ),
      PickerField<String>(
        label: 'Aspect ratio',
        value: crop.ratio,
        options: [
          for (final r in crop.ratioChoices)
            PickerOption(r, switch (r) { 'free' => 'Free', 'original' => 'Original', _ => r }),
        ],
        onChanged: crop.setRatio,
      ),
      _geometry(c, 'straighten'),
      InfoRow('Crop size', '${size.width.round()} × ${size.height.round()}'),
    ]),
    Section(title: 'Perspective', children: [
      _geometry(c, 'perspectiveVertical', 'perspectiveV'),
      _geometry(c, 'perspectiveHorizontal', 'perspectiveH'),
    ]),
    Section(title: 'Finish', children: [
      PillButton('Reset Crop', expand: true, onPressed: crop.reset),
      PillButton('Done', expand: true, variant: ButtonVariant.accent, onPressed: crop.done),
    ]),
  ];
}

/// A geometry slider: the catalogue's control, kept at the edit's top level under `key`.
Widget _geometry(InspectorControls c, String field, [String? key]) {
  final s = c.catalogue.catalogueSlider(field, '', 0.1);
  final at = key ?? field;
  return AdjustmentRow(
    key: ValueKey(at),
    label: s.label,
    detail: s.detail,
    value: (c.edit[at] as num?)?.toDouble() ?? 0,
    range: SliderRange(min: s.min, max: s.max, step: s.step, def: s.def),
    ends: c.catalogue.sliderEnds(field),
    onChanged: (v) => c.editor.crop.setGeometry(at, v),
    onEnd: c.editor.endEdit,
  );
}

/// Spectrum's secondary Button at size S with an icon, as the orientation row has them
/// (inspector.css `.crop-actions button`).
class _ActionButton extends StatefulWidget {
  const _ActionButton({required this.icon, required this.label, required this.onPressed});
  final String icon, label;
  final VoidCallback onPressed;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final bg = palette.gray100;
    return tinted(
      onTap: widget.onPressed,
      child: Container(
        height: Metrics.control,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: pressed
              ? Color.lerp(bg, palette.text, .12)
              : hovered
                  ? Color.lerp(bg, palette.text, .06)
                  : bg,
          borderRadius: BorderRadius.circular(Metrics.control / 2),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          AppIcon(widget.icon, size: 16, color: palette.text),
          const SizedBox(width: 4),
          Flexible(
            child: Text(widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: editorText(context, size: TextSizes.label, weight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }
}

/// Spectrum's ToggleButton at size S: grey at rest, the neutral fill while selected.
class _ToggleButton extends StatefulWidget {
  const _ToggleButton({required this.label, required this.selected, required this.onPressed});
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_ToggleButton> createState() => _ToggleButtonState();
}

class _ToggleButtonState extends State<_ToggleButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final bg = widget.selected ? palette.gray800 : palette.gray100;
    return tinted(
      onTap: widget.onPressed,
      selected: widget.selected,
      child: Container(
        height: Metrics.control,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hovered ? Color.lerp(bg, palette.text, .06) : bg,
          borderRadius: BorderRadius.circular(Metrics.radius),
        ),
        child: Text(widget.label,
            style: editorText(context,
                weight: FontWeight.w700,
                color: widget.selected ? palette.onSelected : palette.text)),
      ),
    );
  }
}
