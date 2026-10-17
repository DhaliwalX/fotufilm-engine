// The web editor's colours (web/src/styles/base.css, responsive.css) and the Spectrum 2 greys its
// components draw with, for the light and dark appearances.
import 'package:flutter/widgets.dart';

class Palette {
  const Palette({
    required this.dark,
    required this.text,
    required this.page,
    required this.panel,
    required this.border,
    required this.muted,
    required this.accent,
    required this.selected,
    required this.canvas,
    required this.gray25,
    required this.gray100,
    required this.gray300,
    required this.gray700,
    required this.gray800,
    required this.fieldFill,
    required this.switchOff,
    required this.popover,
    required this.tooltip,
    required this.systemColors,
  });

  final bool dark;
  final Color text, page, panel, border, muted, accent, selected, canvas;

  /// Spectrum's greys: 25 is the lightest surface, 800 the neutral fill of a selected toggle.
  final Color gray25, gray100, gray300, gray700, gray800;
  final Color fieldFill, switchOff, popover, tooltip;

  /// The colours Fotufilm's glyphs paint their coloured parts with (`--fotu-system*`).
  final Map<String, Color> systemColors;

  /// The text and icon colour on a selected toggle.
  Color get onSelected => gray25;
  Color get hover => text.withValues(alpha: .07);
  Color get pressed => text.withValues(alpha: .12);

  static const light = Palette(
    dark: false,
    text: Color(0xFF242628),
    page: Color(0xFFE8E9EB),
    panel: Color(0xFFF4F4F5),
    border: Color(0xFFD6D7DA),
    muted: Color(0xFF73767B),
    accent: Color(0xFF326CD5),
    selected: Color(0xFFDDE7F8),
    canvas: Color(0xFFE1E2E5),
    gray25: Color(0xFFFFFFFF),
    gray100: Color(0xFFE9E9E9),
    gray300: Color(0xFFDADADA),
    gray700: Color(0xFF505050),
    gray800: Color(0xFF292929),
    fieldFill: Color(0x0D000000),
    switchOff: Color(0x24000000),
    popover: Color(0xFFFFFFFF),
    tooltip: Color(0xFF292929),
    systemColors: {
      'Red': Color(0xFFFF3B30),
      'Orange': Color(0xFFFF9500),
      'Yellow': Color(0xFFFFCC00),
      'Green': Color(0xFF34C759),
      'Cyan': Color(0xFF32ADE6),
      'Blue': Color(0xFF007AFF),
      'Purple': Color(0xFFAF52DE),
      'Pink': Color(0xFFFF2D55),
    },
  );

  static const darkPalette = Palette(
    dark: true,
    text: Color(0xFFE2E3E6),
    page: Color(0xFF202124),
    panel: Color(0xFF292A2D),
    border: Color(0xFF3D3F43),
    muted: Color(0xFFA0A3AA),
    accent: Color(0xFF8AAEFA),
    selected: Color(0xFF364761),
    canvas: Color(0xFF202124),
    gray25: Color(0xFF111111),
    gray100: Color(0xFF2C2C2C),
    gray300: Color(0xFF393939),
    gray700: Color(0xFFAFAFAF),
    gray800: Color(0xFFDBDBDB),
    fieldFill: Color(0x14FFFFFF),
    switchOff: Color(0x33FFFFFF),
    popover: Color(0xFF2C2C2C),
    tooltip: Color(0xFFDBDBDB),
    systemColors: {
      'Red': Color(0xFFFF453A),
      'Orange': Color(0xFFFF9F0A),
      'Yellow': Color(0xFFFFD60A),
      'Green': Color(0xFF30D158),
      'Cyan': Color(0xFF64D2FF),
      'Blue': Color(0xFF0A84FF),
      'Purple': Color(0xFFBF5AF2),
      'Pink': Color(0xFFFF375F),
    },
  );

  static Palette of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaletteScope>()?.palette ?? light;
}

class PaletteScope extends InheritedWidget {
  const PaletteScope({super.key, required this.palette, required super.child});
  final Palette palette;

  @override
  bool updateShouldNotify(PaletteScope oldWidget) => oldWidget.palette != palette;
}
