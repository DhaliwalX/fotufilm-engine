// The phone's editor: always dark, black around the picture, with the controls in a docked sheet
// over a bar of the editing groups. Its sizes are laid out under the phone's 1.25 times scale
// (app/touch_scale.dart), so a 44 point button here is 35.
import 'package:flutter/widgets.dart';

import 'palette.dart';

/// Whether the screen is a phone's: a mobile platform narrower than a tablet on its shorter side.
/// `FOTUFILM_PHONE=1` (a query parameter in a browser) gives any window the phone's editor.
bool phoneScreen(Size size, {required bool mobile, bool forced = false}) =>
    forced || (mobile && size.shortestSide < 600);

/// Marks the phone's editor, so the shared controls take the phone's look inside it.
class PhoneStyle extends InheritedWidget {
  const PhoneStyle({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PhoneStyle>() != null;

  @override
  bool updateShouldNotify(PhoneStyle oldWidget) => false;
}

/// The phone's colours: the dark palette on black, with a yellow accent.
const phonePalette = Palette(
  dark: true,
  text: Color(0xFFF2F2F2),
  page: Color(0xFF000000),
  panel: Color(0xFF161616),
  border: Color(0xFF2C2C2C),
  muted: Color(0xFF9A9A9A),
  accent: Color(0xFFF2C717),
  selected: Color(0xFF3A3A3A),
  canvas: Color(0xFF000000),
  gray25: Color(0xFF111111),
  gray100: Color(0xFF262626),
  gray300: Color(0xFF3A3A3A),
  gray700: Color(0xFFB4B4B4),
  gray800: Color(0xFFE6E6E6),
  fieldFill: Color(0x1AFFFFFF),
  switchOff: Color(0x33FFFFFF),
  popover: Color(0xFF262626),
  tooltip: Color(0xFFE6E6E6),
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

abstract final class PhoneMetrics {
  // ── Top bar ────────────────────────────────────────────────────────────────────────────────
  static const topBar = 44.0;
  static const roundButton = 34.0;
  static const roundIcon = 17.0;

  // ── The bar of groups ──────────────────────────────────────────────────────────────────────
  static const deckBar = 50.0;
  static const deckButton = 54.0;
  static const deckIcon = 20.0;

  // ── The sheet ──────────────────────────────────────────────────────────────────────────────
  /// The sheet's height until its grabber moves it, and the least it can be dragged to.
  static const sheet = 258.0, sheetMin = 150.0;
  static const grabber = 14.0;
  static const tabs = 30.0;
  static const tabIcon = 11.0;
  static const sheetPadding = EdgeInsets.fromLTRB(16, 8, 16, 16);
  static const controlGap = 10.0;

  // ── Sliders ────────────────────────────────────────────────────────────────────────────────
  static const sliderTrack = 5.0;
  static const sliderKnob = 18.0;
  static const sliderHeight = 28.0;
  static const endGlyph = 12.0;

  // ── Films ──────────────────────────────────────────────────────────────────────────────────
  static const filmTile = 93.0, filmGap = 8.0;
  static const chips = 28.0;
}

/// The phone's caps label: small, bold and spaced.
TextStyle capsText(BuildContext context, {Color? color, double size = 9}) => TextStyle(
      fontFamily: 'Satoshi',
      fontSize: size,
      fontWeight: FontWeight.w700,
      letterSpacing: size * .12,
      height: 1.3,
      color: color ?? Palette.of(context).text,
      decoration: TextDecoration.none,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
