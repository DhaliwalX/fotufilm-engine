import Foundation

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Asking the home screen to redraw.
enum WidgetReload {
    static func recents() async {
        #if canImport(WidgetKit) && !os(macOS)
        WidgetCenter.shared.reloadTimelines(
            ofKind: "com.muastudio.fotufilm.recent")
        #endif
    }
}
