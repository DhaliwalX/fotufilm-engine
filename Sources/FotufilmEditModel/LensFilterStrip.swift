import Foundation

/// What a tap on the lens strip does to the fitted stack.
///
/// The strip offers bare glass and then every filter, one tile each, and a stack is built by
/// tapping: a filter not yet on the lens goes on behind the ones already there, a filter that is
/// on comes off again, and bare glass takes the whole stack off. The tiles that read as chosen
/// are the ones the stack carries — or bare glass, when it carries nothing.
public enum LensFilterStrip {
    /// The stack after a tap on `tile`, nil meaning bare glass. A filter fitted twice comes off
    /// from the back, the way it went on.
    public static func toggled(_ ids: [String], tile: String?) -> [String] {
        guard let tile else { return [] }
        var next = ids
        if let index = ids.lastIndex(of: tile) {
            next.remove(at: index)
        } else {
            next.append(tile)
        }
        return next
    }

    /// Whether `tile` — nil for bare glass — reads as chosen against `ids`.
    public static func isFitted(_ tile: String?, in ids: [String]) -> Bool {
        guard let tile else { return ids.isEmpty }
        return ids.contains(tile)
    }
}
