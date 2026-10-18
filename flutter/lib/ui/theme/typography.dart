// The editor's type: Satoshi on every element, with tabular figures so values do not shift as
// they change.
import 'package:flutter/widgets.dart';

import 'palette.dart';

const editorFont = 'Satoshi';

abstract final class TextSizes {
  static const caption = 10.0;
  static const label = 11.0;
  static const body = 12.0;
  static const menu = 12.5;
  static const section = 13.0;
  static const heading = 14.0;
  static const dialog = 18.0;
}

TextStyle editorText(
  BuildContext context, {
  double size = TextSizes.body,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double? height,
}) =>
    TextStyle(
      fontFamily: editorFont,
      fontSize: size,
      fontWeight: weight,
      color: color ?? Palette.of(context).text,
      height: height,
      decoration: TextDecoration.none,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
