// The editor's icons as web/src/icons.jsx draws them: Fotufilm's own glyphs where the set has
// one (glyph-names.js ICON_GLYPHS), Material Symbols Rounded otherwise. Glyphs colour their
// primary layer with the text colour and their coloured parts with the system colours.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/theme.dart';

class IconLibrary {
  IconLibrary._(this._symbols, this._glyphs);

  final Map<String, String> _symbols;
  final Map<String, String> _glyphs;

  static late IconLibrary shared;

  static const iconGlyphs = {
    'film': 'fotu.deck.film',
    'expose': 'fotu.deck.light',
    'develop': 'fotu.tab.lab',
    'print': 'fotu.deck.print',
    'adjustments': 'fotu.deck.controls',
    'selective': 'fotu.tab.local',
    'crop': 'fotu.tab.geometry',
    'lens': 'fotu.deck.lens',
  };

  static Future<void> load() async {
    final symbols = jsonDecode(
        await rootBundle.loadString('assets/generated/material-symbols.json')) as Map;
    final svgs = <String, String>{};
    for (final MapEntry(:key, :value) in symbols.entries) {
      final paths = (value['paths'] as List).map((d) => '<path d="$d"/>').join();
      svgs[key as String] =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="${value['viewBox']}" fill="currentColor">$paths</svg>';
    }
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final glyphs = <String, String>{};
    for (final asset in manifest.listAssets()) {
      if (!asset.startsWith('assets/generated/glyphs/')) continue;
      final name = asset.split('/').last.replaceAll(RegExp(r'\.svg$'), '');
      glyphs[name] = await rootBundle.loadString(asset);
    }
    shared = IconLibrary._(svgs, glyphs);
  }

  static final _system = RegExp(r'var\(--fotu-system(\w+),\s*(#[0-9A-Fa-f]{6})\)');

  String? glyph(String name, Palette palette) => _glyphs[name]?.replaceAllMapped(_system, (m) {
        final color = palette.systemColors[m[1]];
        if (color == null) return m[2]!;
        final argb = color.toARGB32();
        return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
      });

  String? symbol(String name) => _symbols[name];
}

/// An editor icon by its app name (`undo`, `film`, `histogram`, …).
class AppIcon extends StatelessWidget {
  const AppIcon(this.name, {super.key, this.size = 20, this.color});
  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final glyph = IconLibrary.iconGlyphs[name];
    if (glyph != null) return Glyph(glyph, size: size, color: color);
    final svg = IconLibrary.shared.symbol(name) ?? IconLibrary.shared.symbol('film')!;
    final tint = color ?? DefaultTextStyle.of(context).style.color ?? Palette.of(context).text;
    return SvgPicture.string(svg,
        width: size, height: size, theme: SvgTheme(currentColor: tint), key: ValueKey('$name$tint'));
  }
}

/// A glyph of Fotufilm's set by its name (`fotu.slider.exposure.low`, …).
class Glyph extends StatelessWidget {
  const Glyph(this.name, {super.key, this.size = 20, this.color});
  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final svg = IconLibrary.shared.glyph(name, palette);
    if (svg == null) return SizedBox(width: size, height: size);
    final tint = color ?? DefaultTextStyle.of(context).style.color ?? palette.text;
    return SvgPicture.string(svg,
        width: size, height: size, theme: SvgTheme(currentColor: tint), key: ValueKey('$name$tint${palette.dark}'));
  }
}
