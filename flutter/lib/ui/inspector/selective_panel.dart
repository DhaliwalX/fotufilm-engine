// The Selective tool's panel (web/src/editor/SelectiveInspector.jsx, SelectiveControls.jsx): what
// the selection is, how far it reaches and whether its mask shows, then the light and colour the
// selected part develops with.
import 'package:flutter/widgets.dart';

import '../../model/catalogue.dart';
import '../../model/selective.dart';
import '../kit/kit.dart';
import 'controls.dart';

List<Widget> selectivePanel(InspectorControls c) {
  final tool = c.editor.selective;
  final spec = tool.spec;
  final selection = tool.selection;
  final subject = tool.subject;
  // A subject selection's rim, or a colour or light selection's reach.
  final reach = (spec[subject ? 'subjectSliders' : 'sliders'] as List).cast<Json>();
  final params = (selection['params'] as Map?) ?? const {};
  Widget button(String label, VoidCallback? onPressed) =>
      Align(alignment: Alignment.centerLeft, child: PillButton(label, onPressed: onPressed));
  return [
    Section(title: spec['section'] as String, children: [
      PickerField<String>(
        label: spec['kind'] as String,
        value: selection['kind'] as String,
        options: [
          for (final choice in tool.choices)
            PickerOption(choice['value'] as String, choice['label'] as String),
        ],
        onChanged: (kind) => tool.change({'kind': kind}),
      ),
      button(spec[tool.sampling ? 'sampling' : 'sample'] as String,
          tool.canSample ? () => tool.setSampling(!tool.sampling) : null),
      if (subject)
        Note(subjectsFound((spec['subjectsFound'] as List).cast<String>(), tool.subjects)),
      for (final s in reach)
        AdjustmentRow(
          key: ValueKey(s['key']),
          label: s['label'] as String,
          value: (selection[s['key']] as num? ?? s['def'] as num).toDouble(),
          range: SliderRange(
            min: (s['min'] as num).toDouble(),
            max: (s['max'] as num).toDouble(),
            step: (s['step'] as num).toDouble(),
            def: (s['def'] as num).toDouble(),
          ),
          onChanged: (v) => tool.change({s['key'] as String: v}, group: 'selective-${s['key']}'),
          onEnd: c.editor.endEdit,
        ),
      SwitchRow(
        label: spec['mask'] as String,
        value: tool.showMask,
        enabled: subject || selection['sample'] != null,
        onChanged: tool.setShowMask,
      ),
      button(spec['clear'] as String, c.edit['selective'] != null ? tool.clear : null),
    ]),
    Section(title: 'Selection Light', children: [
      for (final s in c.catalogue.sliders)
        if (selectionKeys.contains(s.key) && !s.key.startsWith('grade'))
          AdjustmentRow(
            key: ValueKey(s.key),
            label: s.label,
            detail: s.detail,
            value: (params[s.key] as num?)?.toDouble() ?? s.def,
            range: SliderRange(min: s.min, max: s.max, step: s.step, def: s.def),
            ends: c.catalogue.sliderEnds(s.key),
            reciprocal: s.key == 'temperature',
            onChanged: (v) => tool.change({
              'params': {...params, s.key: v},
            }, group: 'selective-${s.key}'),
            onEnd: c.editor.endEdit,
          ),
      SwitchRow(
        label: 'Regional',
        value: selection['localTone'] == true,
        onChanged: (v) => tool.change({'localTone': v}),
      ),
      button(spec['match'] as String, tool.matchPhotograph),
    ]),
  ];
}
