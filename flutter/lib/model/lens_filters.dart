// Filters on the lens (web/src/lens-filters.js): the catalogue's filters, which of them scatter
// light rather than absorb it, and the edits that fit, swap, reorder and take them off. The first
// filter in the list sits nearest the lens.
import 'catalogue.dart';

class LensFilterCatalogue {
  LensFilterCatalogue(this.json);

  /// The control catalogue's `LENS_FILTERS`.
  LensFilterCatalogue.of(Catalogue catalogue)
      : json = catalogue.module['LENS_FILTERS'] as Json;

  final Json json;

  /// The filters the Add Filter menu offers.
  List<Json> get choices => (json['choices'] as List).cast<Json>();

  /// How an exposure is metered through absorbing filters.
  List<Json> get meterings => (json['meterings'] as List).cast<Json>();

  List<String> get supported => (json['supported'] as List).cast<String>();

  Json? choice(String id) => choices.where((c) => c['id'] == id).firstOrNull;

  /// A filter's name; one the menu no longer offers keeps the name it was saved under.
  String name(String id) =>
      (choice(id)?['name'] ?? (json['names'] as Map?)?[id] ?? id) as String;

  /// Diffusion filters (Pro-Mist 1/4, Fog 1, …) scatter; the rest absorb.
  bool isDiffusion(String id) => supported.contains(id) && id.contains('-');

  /// A warning under the filters, or null.
  String? note(List<String> filters) =>
      filters.where(isDiffusion).length > 1 ? 'Only the first diffusion filter acts.' : null;

  /// The colours an absorbing filter passes, short to long wavelengths, for its swatch.
  List<List<int>>? spectrum(String id) => (choice(id)?['spectrum'] as List?)
      ?.map((rgb) => (rgb as List).cast<num>().map((v) => v.toInt()).toList())
      .toList();
}

/// The stack with the filter at `index` swapped for `id`, or taken off when `id` is "none".
List<String> replaceFilter(List<String> filters, int index, String id) => id == 'none'
    ? [for (var i = 0; i < filters.length; i++) if (i != index) filters[i]]
    : [for (var i = 0; i < filters.length; i++) i == index ? id : filters[i]];

/// The stack with the filter at `index` moved `delta` places (−1 nearer the lens).
List<String> moveFilter(List<String> filters, int index, int delta) {
  final to = index + delta;
  if (to < 0 || to >= filters.length) return filters;
  final next = [...filters];
  next[index] = filters[to];
  next[to] = filters[index];
  return next;
}
