// Spectrum's fields at size S: a bare text field, the switch, the picker and the info row.
import 'package:flutter/material.dart'
    show InputBorder, InputDecoration, Material, MaterialType, TextField, TextSelectionTheme,
        TextSelectionThemeData;
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'buttons.dart';
import 'help.dart';
import 'icons.dart';
import 'menu.dart';

/// A text field in the editor's type with no chrome of its own; callers draw the fill.
class EditableField extends StatelessWidget {
  const EditableField({
    super.key,
    required this.controller,
    this.focusNode,
    required this.style,
    this.onSubmitted,
    this.onChanged,
    this.placeholder,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextStyle style;
  final ValueChanged<String>? onSubmitted, onChanged;
  final String? placeholder;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: TextSelectionTheme(
        data: TextSelectionThemeData(
          cursorColor: palette.accent,
          selectionColor: palette.accent.withValues(alpha: .3),
        ),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          style: style,
          cursorHeight: style.fontSize! + 2,
          cursorWidth: 1.2,
          onSubmitted: onSubmitted,
          onChanged: onChanged,
          decoration: InputDecoration(
            isDense: true,
            isCollapsed: true,
            border: InputBorder.none,
            hintText: placeholder,
            hintStyle: style.copyWith(color: palette.muted),
          ),
        ),
      ),
    );
  }
}

/// A name above a control, with the catalogue's help beside it.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.label, {super.key, this.detail});
  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) => Row(children: [
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: editorText(context, size: TextSizes.label,
                  color: Palette.of(context).text.withValues(alpha: .75))),
        ),
        HelpButton(detail: detail),
      ]);
}

/// Spectrum's Switch at size S, with its label and help.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.detail,
    this.enabled = true,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? detail;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: Row(children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => onChanged(!value) : null,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 23,
              height: 13,
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                color: value ? palette.gray800 : palette.switchOff,
                borderRadius: BorderRadius.circular(7),
              ),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: palette.gray25, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: 8),
            Text(label, style: editorText(context, size: TextSizes.label)),
          ]),
        ),
        HelpButton(detail: detail),
      ]),
    );
  }
}

class PickerOption<T> {
  const PickerOption(this.value, this.label, {this.enabled = true});
  final T value;
  final String label;

  /// Listed but greyed out (Spectrum's `disabledKeys`).
  final bool enabled;
}

/// Spectrum's Picker at size S: its label above, a filled field with the choice and a chevron,
/// and a menu of the choices under it.
class PickerField<T> extends StatelessWidget {
  const PickerField({
    super.key,
    this.label,
    this.detail,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
    this.placeholder,
  });

  final String? label, detail;

  /// Shown when `value` is none of the options.
  final String? placeholder;
  final T value;
  final List<PickerOption<T>> options;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final current = options.where((o) => o.value == value).firstOrNull;
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (label != null) ...[
          FieldLabel(label!, detail: detail),
          const SizedBox(height: 3),
        ],
        Builder(
          builder: (anchor) => PressTrigger(
            onPress: enabled
                ? () => showMenu(anchor, matchWidth: true, [
                      for (final o in options)
                        MenuItem(
                          label: o.label,
                          checked: o.value == value,
                          onSelected: o.enabled ? () => onChanged(o.value) : null,
                        ),
                    ])
                : null,
            child: Container(
              height: Metrics.control,
              padding: const EdgeInsets.only(left: 8, right: 6),
              decoration: BoxDecoration(
                  color: palette.gray100, borderRadius: BorderRadius.circular(Metrics.radius)),
              child: Row(children: [
                Expanded(
                  child: Text(current?.label ?? placeholder ?? '',
                      overflow: TextOverflow.ellipsis, style: editorText(context)),
                ),
                AppIcon('chevronDown', size: 16),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// A label on the left and a muted value on the right (`.info-row`).
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});
  final String label, value;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: editorText(context, size: TextSizes.label)),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: editorText(context, size: TextSizes.label, color: Palette.of(context).muted)),
          ),
        ],
      );
}

/// A muted note under controls (`.medium-detail`).
class Note extends StatelessWidget {
  const Note(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: editorText(context, size: TextSizes.label, color: Palette.of(context).muted, height: 1.45));
}
