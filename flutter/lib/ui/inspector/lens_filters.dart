// The Expose panel's Filters (web/src/LensFilters.jsx, LensFilters.css, FilterSwatch.jsx): the
// filters on the lens, nearest first, each with its swatch, its menu and its buttons to move it
// or take it off; the menu to add one; how the exposure is metered through them.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/catalogue.dart';
import '../../model/lens_filters.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'controls.dart';

Widget lensFiltersSection(InspectorControls c) {
  final editor = c.editor;
  final catalogue = LensFilterCatalogue.of(c.catalogue);
  final filters = ((c.edit['filters'] as List?) ?? const []).cast<String>();
  // A filter change develops at once, as one step.
  void change(Json value) => editor.change(value);
  final options = [for (final f in catalogue.choices) PickerOption(f['id'] as String, f['name'] as String)];
  final note = catalogue.note(filters);
  return Section(title: 'Filters', children: [
    for (var i = 0; i < filters.length; i++)
      _FittedFilter(
        // The same filter twice keeps each row its own.
        key: ValueKey('${filters[i]}:${filters.take(i).where((f) => f == filters[i]).length}'),
        id: filters[i],
        index: i,
        count: filters.length,
        catalogue: catalogue,
        stock: c.stock,
        options: [
          const PickerOption('none', 'None'),
          ...options,
          if (catalogue.choice(filters[i]) == null)
            PickerOption(filters[i], catalogue.name(filters[i])),
        ],
        onReplace: (id) => change({'filters': replaceFilter(filters, i, id)}),
        onMove: (delta) => change({'filters': moveFilter(filters, i, delta)}),
      ),
    PickerField<String>(
      label: 'Add Filter',
      value: 'none',
      options: [const PickerOption('none', 'Add Filter…'), ...options],
      onChanged: (id) {
        if (id != 'none') change({'filters': [...filters, id]});
      },
    ),
    if (filters.any((id) => !catalogue.isDiffusion(id)))
      PickerField<String>(
        label: 'Metering',
        value: c.edit['filterMetering'] as String? ?? 'throughTheLens',
        options: [
          for (final m in catalogue.meterings) PickerOption(m['id'] as String, m['name'] as String),
        ],
        onChanged: (v) => change({'filterMetering': v}),
      ),
    if (filters.isNotEmpty)
      Align(
        alignment: Alignment.centerLeft,
        child: QuietButton(label: 'Take Them All Off', onPressed: () => change({'filters': []})),
      ),
    if (note != null) Note(note),
  ]);
}

class _FittedFilter extends StatelessWidget {
  const _FittedFilter({
    super.key,
    required this.id,
    required this.index,
    required this.count,
    required this.catalogue,
    required this.stock,
    required this.options,
    required this.onReplace,
    required this.onMove,
  });

  final String id;
  final int index, count;
  final LensFilterCatalogue catalogue;
  final Json? stock;
  final List<PickerOption<String>> options;
  final ValueChanged<String> onReplace;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) => Row(children: [
        FilterSwatch(id: id, catalogue: catalogue, stock: stock),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PickerField<String>(value: id, options: options, onChanged: onReplace),
            const SizedBox(height: 2),
            Text(catalogue.isDiffusion(id) ? 'Scatters' : 'Absorbs',
                style: editorText(context, size: TextSizes.caption, color: Palette.of(context).muted)),
          ]),
        ),
        const SizedBox(width: 6),
        QuietButton(
          tooltip: 'Move filter nearer the lens',
          onPressed: index == 0 ? null : () => onMove(-1),
          icon: 'chevronDown',
          iconSize: 16,
          upsideDown: true,
        ),
        const SizedBox(width: 2),
        QuietButton(
          tooltip: 'Move filter further from the lens',
          onPressed: index == count - 1 ? null : () => onMove(1),
          icon: 'chevronDown',
          iconSize: 16,
        ),
        const SizedBox(width: 2),
        QuietButton(
          tooltip: 'Take this filter off',
          onPressed: () => onReplace('none'),
          icon: 'minus',
          iconSize: 16,
        ),
      ]);
}

/// A filter's swatch (FilterSwatch.jsx): the colours an absorbing filter passes across the
/// spectrum, or for a diffusion filter, three points of light through its halo on this film.
class FilterSwatch extends StatelessWidget {
  const FilterSwatch({super.key, required this.id, required this.catalogue, this.stock});
  final String id;
  final LensFilterCatalogue catalogue;
  final Json? stock;

  static const size = 26.0;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final spectrum = catalogue.isDiffusion(id) ? null : catalogue.spectrum(id);
    final halo = ((stock?['profile'] as Map?)?['filterHalos'] as Map?)?[id] as Map?;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(5),
        gradient: spectrum == null || spectrum.length < 2
            ? null
            : LinearGradient(colors: [
                for (final rgb in spectrum) Color.fromARGB(255, rgb[0], rgb[1], rgb[2]),
              ]),
      ),
      clipBehavior: Clip.antiAlias,
      child: catalogue.isDiffusion(id) && halo != null
          ? CustomPaint(painter: _HaloPainter(halo))
          : null,
    );
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter(this.halo);
  final Map halo;

  static const _n = 26;
  static const _lights = [(0.18, 0.5), (0.5, 0.34), (0.82, 0.62)];

  @override
  void paint(Canvas canvas, Size size) {
    final direct = (halo['direct'] as num).toDouble();
    final scattered = (halo['scattered'] as num).toDouble();
    final sigmas = [for (final s in halo['sigmas'] as List) (s as num).toDouble()];
    final weights = [for (final w in halo['weights'] as List) (w as num).toDouble()];
    final values = List.filled(_n * _n, 0.0);
    var peak = 0.0;
    for (var y = 0; y < _n; y++) {
      for (var x = 0; x < _n; x++) {
        var value = 0.015;
        for (final (sx, sy) in _lights) {
          final r = math.pow(x - sx * _n, 2) + math.pow(y - sy * _n, 2);
          value += direct * math.exp(-r / 20);
          for (var i = 0; i < sigmas.length; i++) {
            value += scattered * weights[i] * math.exp(-r / (2 * math.pow(math.max(sigmas[i], .5), 2)));
          }
        }
        values[y * _n + x] = value;
        peak = math.max(peak, value);
      }
    }
    final cell = size.width / _n;
    for (var i = 0; i < values.length; i++) {
      final level = (math.min(values[i] / peak, 1) * 255).round();
      canvas.drawRect(
          Rect.fromLTWH((i % _n) * cell, (i ~/ _n) * cell, cell + .5, cell + .5),
          Paint()..color = Color.fromARGB(255, level, level, level));
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) => old.halo != halo;
}
