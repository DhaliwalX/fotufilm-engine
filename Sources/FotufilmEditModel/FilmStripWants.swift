import Foundation

/// Which tiles a film strip has developed: the ones on screen, and a bounded few beyond them.
///
/// With every film on every medium the strip is hundreds of tiles long, and developing the run
/// end to end would spend seconds on pictures nobody scrolls to. The strip instead names what it
/// can see and the store develops that plus `beyond` more, alternating outward from either end
/// of the visible run so the next tile the finger reaches is already developing whichever way it
/// goes.
public enum FilmStripWants {
    /// The default number of tiles kept ready past the visible run.
    public static let defaultBeyond = 5

    /// The tile indices to develop, nearest first: `visible` in order, then up to `beyond` more
    /// taken alternately from just after and just before it, never past either end of `count`.
    public static func indices(visible: Range<Int>, of count: Int,
                               beyond: Int = defaultBeyond) -> [Int] {
        guard count > 0 else { return [] }
        let visible = visible.clamped(to: 0..<count)
        var run = Array(visible)
        let limit = visible.count + max(0, beyond)
        var after = visible.upperBound
        var before = visible.lowerBound - 1
        while run.count < limit, after < count || before >= 0 {
            if after < count {
                run.append(after)
                after += 1
            }
            if run.count < limit, before >= 0 {
                run.append(before)
                before -= 1
            }
        }
        return run
    }
}
