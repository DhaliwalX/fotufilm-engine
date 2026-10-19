// The editor at a phone's size: its sizes are the desktop's (Spectrum size S, 12 px type), so on a
// phone everything is laid out smaller and drawn larger, as a browser's zoom does. The menus,
// dialogs and popovers grow with the panels, and the screen's pixel ratio grows to match, so the
// photograph still develops at the screen's resolution.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// How much larger a phone draws the editor.
const phoneScale = 1.25;

/// A phone or tablet, in its own app or its browser: touch first, and no keyboard shortcuts.
bool get mobilePlatform =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// The scale for a screen `size` across: a phone's (a mobile platform, narrower than a tablet on
/// its shorter side), or none.
double touchScale(Size size) => mobilePlatform && size.shortestSide < 600 ? phoneScale : 1;

class TouchScale extends StatelessWidget {
  const TouchScale({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    final k = touchScale(data.size);
    if (k == 1) return child;
    final size = data.size / k;
    return MediaQuery(
      data: data.copyWith(
        size: size,
        devicePixelRatio: data.devicePixelRatio * k,
        padding: data.padding / k,
        viewPadding: data.viewPadding / k,
        viewInsets: data.viewInsets / k,
        systemGestureInsets: data.systemGestureInsets / k,
      ),
      child: ClipRect(
        child: Transform.scale(
          scale: k,
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: size.width,
            maxWidth: size.width,
            minHeight: size.height,
            maxHeight: size.height,
            child: child,
          ),
        ),
      ),
    );
  }
}
