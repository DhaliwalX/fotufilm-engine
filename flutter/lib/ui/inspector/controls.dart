// What every inspector panel builds with: the edit it shows, and rows for the catalogue's controls,
// so a panel only says which controls go in which section.
import 'package:flutter/widgets.dart';

import '../../app/strings.dart';
import '../../model/catalogue.dart';
import '../../model/editor.dart';
import '../kit/kit.dart';
import 'spectrum_curve.dart';

class InspectorControls {
  InspectorControls(this.editor);

  final EditorModel editor;
  Catalogue get catalogue => editor.catalogue;
  Json get edit => editor.edit;
  Json? get stock => editor.selectedStock;
  bool get hasFilm => edit['stock'] != null;
  Map get params => edit['params'] as Map;
  Map get profile => edit['profile'] as Map;
  List get available => (stock?['available'] as List?) ?? const [];

  /// A film whose profile cannot be changed (stock-settings.js `fixedStockSettings`).
  bool get fixedSettings => (stock?['profile'] as Map?)?['settings'] == 'fixed';

  /// The editor's own sliders of a group. Without a film, the film-only ones are left out, as
  /// they are with `film` false (a scanned negative's light, which acts on its print).
  List<Widget> sliders(String group, {bool film = true}) => [
        for (final s in catalogue.sliders)
          if (s.group == group && ((film && hasFilm) || s.availability != 'film'))
            AdjustmentRow(
              key: ValueKey(s.key),
              label: s.label,
              detail: s.detail,
              value: (params[s.key] as num?)?.toDouble() ?? s.def,
              range: SliderRange(min: s.min, max: s.max, step: s.step, def: s.def),
              ends: catalogue.sliderEnds(s.key),
              reciprocal: s.key == 'temperature',
              onChanged: (v) => editor.setParam(s.key, v),
              onEnd: editor.endEdit,
            ),
      ];

  /// A switch for a top-level field of the edit.
  Widget editSwitch(String field, String label) => SwitchRow(
        key: ValueKey(field),
        label: label,
        detail: catalogue.detail(field),
        value: edit[field] == true,
        onChanged: (v) => editor.change({field: v}),
      );

  // The printer's lights only act with the printer on, and the print correction only without.
  static const _printerLights = ['printerLamp', 'printerExposure', 'printerMagenta', 'printerYellow'];

  bool _inactive(String field) =>
      (_printerLights.contains(field) && profile['printerEnabled'] != true) ||
      (field == 'printCorrection' && profile['printerEnabled'] == true);

  /// The film's profile controls among `fields`, those this film and medium have. A fixed
  /// profile has none.
  List<Widget> profileControls(List<String> fields) => [
        if (!fixedSettings)
          for (final c in catalogue.profileFields(fields, edit, stock)) _profileControl(c),
      ];

  Widget _profileControl(Json c) {
    final field = c['field'] as String;
    final value = profile[field] ?? Catalogue.profileDefault(c);
    final title = c['title'] as String;
    final detail = c['detail'] as String?;
    final enabled = !_inactive(field);
    void set(Object? v) => editor.setProfile(field, v, grouped: false);

    if (c['curve'] case final Json curve) {
      return SpectrumCurve(
        key: ValueKey(field),
        title: title,
        detail: detail,
        curve: curve,
        values: [for (final v in value as List) (v as num).toDouble()],
        enabled: enabled,
        onChanged: (values) => editor.setProfile(field, values),
        onReset: () => set(Catalogue.profileDefault(c)),
        onEnd: editor.endEdit,
      );
    }
    if (c['kind'] == 'toggle') {
      return SwitchRow(
        key: ValueKey(field),
        label: title,
        detail: detail,
        value: value == true,
        enabled: enabled,
        onChanged: set,
      );
    }
    if (c['kind'] == 'chips') {
      return PickerField<num>(
        key: ValueKey(field),
        label: title,
        detail: detail,
        value: value as num,
        enabled: enabled,
        options: [
          for (final chip in (c['chips'] as List).cast<Json>())
            PickerOption(chip['value'] as num, chip['label'] as String),
        ],
        onChanged: set,
      );
    }
    if (c['scale'] case final Json scale) {
      final slider = _scaleControl(c, scale, value as num, enabled);
      if (field != 'halationReturn') return slider;
      // The return follows the film until it is moved; this gives it back to the film.
      return Column(
        key: ValueKey(field),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          slider,
          QuietButton(
            label: AppStrings.tr('Use Film Return'),
            onPressed: enabled && profile.containsKey(field) ? () => set(null) : null,
          ),
        ],
      );
    }
    final choices = ((c['choices'] as List?) ?? const []).cast<Json>();
    final ids = choices.map((ch) => ch['id']).toList();
    return PickerField<Object?>(
      key: ValueKey(field),
      label: title,
      detail: detail,
      value: ids.contains(value) ? value : Catalogue.profileDefault(c),
      enabled: enabled,
      options: [
        for (final ch in choices) PickerOption(ch['id'], (ch['label'] ?? ch['name']) as String),
      ],
      onChanged: set,
    );
  }

  /// A slider over a profile scale: percentages shown ×100, and scales with stops snap to them.
  Widget _scaleControl(Json c, Json scale, num value, bool enabled) {
    final field = c['field'] as String;
    final percent = scale['unit'] == 'percent';
    final factor = percent ? 100.0 : 1.0;
    final stops = ((scale['stops'] as List?) ?? const []).cast<num>();
    final neutral = (scale['neutral'] as num).toDouble();
    var current = value.toDouble();
    if (field == 'push' && !stops.contains(current)) current = neutral;
    final step = percent || scale['unit'] == 'printerPoints' || stops.isNotEmpty ? 1.0 : 0.01;
    return AdjustmentRow(
      key: ValueKey(field),
      label: c['title'] as String,
      detail: c['detail'] as String?,
      value: current * factor,
      range: SliderRange(
        min: (scale['min'] as num) * factor,
        max: (scale['max'] as num) * factor,
        step: step,
        def: neutral * factor,
      ),
      ends: catalogue.sliderEnds(field),
      enabled: enabled,
      onChanged: (next) {
        final v = next / factor;
        editor.setProfile(
            field,
            stops.isEmpty
                ? v
                : stops.reduce((best, s) => (s - v).abs() < (best - v).abs() ? s : best));
      },
      onEnd: editor.endEdit,
    );
  }
}
