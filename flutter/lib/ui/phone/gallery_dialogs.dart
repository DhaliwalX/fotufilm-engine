// The gallery's dialogs: a roll's name and the day it was shot, and the questions asked before a
// photograph or a roll is deleted.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import '../workspace/app_dialogs.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
];

/// A day as the gallery writes it: Nov 11, 2026.
String dayText(DateTime day) => '${_months[day.month - 1]} ${day.day}, ${day.year}';

/// How many frames a roll holds, in words.
String framesText(int count) => count == 1 ? '1 frame' : '$count frames';

// ── A roll's name and date ───────────────────────────────────────────────────────────────────

/// New Roll…, or Rename and Date… for `roll`. A new roll takes `frame` with it.
void showRollDialog(BuildContext context, Gallery gallery,
        {GalleryRoll? roll, GalleryEntry? frame}) =>
    showModal(context,
        (close) => _RollDialog(gallery: gallery, roll: roll, frame: frame, onClose: close));

class _RollDialog extends StatefulWidget {
  const _RollDialog({required this.gallery, this.roll, this.frame, required this.onClose});
  final Gallery gallery;
  final GalleryRoll? roll;
  final GalleryEntry? frame;
  final VoidCallback onClose;

  @override
  State<_RollDialog> createState() => _RollDialogState();
}

class _RollDialogState extends State<_RollDialog> {
  late final _name = TextEditingController(text: widget.roll?.name ?? '');
  final _focus = FocusNode();
  late DateTime _day = widget.roll?.day ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Changes part of the date; a month with fewer days takes its last.
  void _set({int? year, int? month, int? day}) {
    final y = year ?? _day.year, m = month ?? _day.month;
    setState(() => _day = DateTime(y, m, math.min(day ?? _day.day, _daysIn(y, m))));
  }

  static int _daysIn(int year, int month) => DateTime(year, month + 1, 0).day;

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final gallery = widget.gallery, roll = widget.roll, frame = widget.frame;
    widget.onClose();
    if (roll != null) return gallery.updateRoll(roll, name: name, date: _day);
    final made = gallery.createRoll(name, _day);
    if (frame != null) gallery.fileIn(frame, made);
  }

  @override
  Widget build(BuildContext context) {
    final latest = math.max(DateTime.now().year, _day.year);
    return AppDialogCard(
      title: widget.roll == null ? 'New Roll' : 'Roll',
      width: 360,
      actions: [
        PillButton('Cancel', onPressed: widget.onClose),
        PillButton(widget.roll == null ? 'Create' : 'Save',
            variant: ButtonVariant.accent,
            onPressed: _name.text.trim().isEmpty ? null : _save),
      ],
      children: [
        Container(
          height: Metrics.control + 4,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
              color: Palette.of(context).gray100,
              borderRadius: BorderRadius.circular(Metrics.radius)),
          child: EditableField(
            controller: _name,
            focusNode: _focus,
            style: editorText(context),
            placeholder: 'Name, such as the film and where it was shot',
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(height: 14),
        const FieldLabel('Date'),
        const SizedBox(height: 3),
        Row(children: [
          Expanded(
            child: _DatePart(
              label: 'Month',
              value: _day.month,
              values: [for (var m = 1; m <= 12; m++) m],
              text: (m) => _months[m - 1],
              onChanged: (m) => _set(month: m),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _DatePart(
              label: 'Day',
              value: _day.day,
              values: [for (var d = 1; d <= _daysIn(_day.year, _day.month); d++) d],
              onChanged: (d) => _set(day: d),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _DatePart(
              label: 'Year',
              value: _day.year,
              // The latest first: most rolls were shot lately.
              values: [for (var y = latest; y >= 1900; y--) y],
              onChanged: (y) => _set(year: y),
              alignEnd: true,
            ),
          ),
        ]),
      ],
    );
  }
}

/// One part of a date, a picker's field: its menu is wider than the field, which is a third of
/// a narrow dialog.
class _DatePart extends StatelessWidget {
  const _DatePart({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
    this.text,
    this.alignEnd = false,
  });

  final String label;
  final int value;
  final List<int> values;
  final ValueChanged<int> onChanged;

  /// What a value reads as, where it is not its number.
  final String Function(int value)? text;
  final bool alignEnd;

  String _text(int value) => text?.call(value) ?? '$value';

  @override
  Widget build(BuildContext context) => Builder(builder: (anchor) {
        void open() => showMenu(anchor, alignEnd: alignEnd, width: 120, [
              for (final v in values)
                MenuItem(label: _text(v), checked: v == value, onSelected: () => onChanged(v)),
            ]);
        return KeyTarget(
          onActivate: open,
          label: label,
          value: _text(value),
          child: PressTrigger(
            onPress: open,
            child: Container(
              height: Metrics.control,
              padding: const EdgeInsets.only(left: 8, right: 6),
              decoration: BoxDecoration(
                  color: Palette.of(context).gray100,
                  borderRadius: BorderRadius.circular(Metrics.radius)),
              child: Row(children: [
                Expanded(
                  child: Text(_text(value),
                      overflow: TextOverflow.ellipsis, style: editorText(context)),
                ),
                const AppIcon('chevronDown', size: 16),
              ]),
            ),
          ),
        );
      });
}

// ── Deleting ─────────────────────────────────────────────────────────────────────────────────

/// Asks before a photograph, a movie or a scan leaves the gallery.
void confirmDelete(BuildContext context, Gallery gallery, GalleryEntry entry) {
  final (title, what) = entry.negative
      ? ('Delete Negative?', 'scan')
      : entry.video
          ? ('Delete Video?', 'video')
          : ('Delete Photo?', 'photograph');
  showModal(
    context,
    (close) => AlertCard(
      title: title,
      message: 'This removes the $what and its Fotufilm edit from this device.',
      primary: 'Delete',
      variant: ButtonVariant.negative,
      onPrimary: () {
        close();
        gallery.delete(entry);
      },
      cancel: 'Cancel',
      onCancel: close,
    ),
  );
}

/// Asks before a roll is deleted, and whether its frames go with it.
void confirmDeleteRoll(BuildContext context, Gallery gallery, GalleryRoll roll) {
  final frames = gallery.framesOf(roll).length;
  void delete(VoidCallback close, {required bool frames}) {
    close();
    gallery.deleteRoll(roll, frames: frames);
  }

  showModal(
    context,
    (close) => AppDialogCard(
      title: 'Delete “${roll.name}”?',
      width: 400,
      actions: [
        PillButton('Cancel', onPressed: close),
        if (frames > 0)
          PillButton('Delete Roll, Keep Frames', onPressed: () => delete(close, frames: false)),
        PillButton(frames > 0 ? 'Delete Roll and Frames' : 'Delete Roll',
            variant: ButtonVariant.negative, onPressed: () => delete(close, frames: true)),
      ],
      children: [
        if (frames > 0)
          Builder(
            builder: (context) => Text(
                'Its ${framesText(frames)} can stay in the gallery outside any roll.',
                style: editorText(context, height: 1.5)),
          ),
      ],
    ),
  );
}
