#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(Dispatch)
import Dispatch
#endif

/// Box-filter reduction of interleaved RGBA floats: every output pixel is the exact area mean of
/// the source it covers, so a preview holds the frame's light and its grain statistics start
/// from the same scene the full develop does.
enum AreaResample {
    static func size(width: Int, height: Int, maxEdge: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard maxEdge > 0, maxEdge < longest else { return (width, height) }
        let scale = Double(maxEdge) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    /// Source spans and weights for one axis.
    private static func taps(from source: Int, to target: Int) -> [(first: Int, weights: [Float])] {
        let step = Double(source) / Double(target)
        return (0..<target).map { index in
            let start = Double(index) * step, end = start + step
            let first = Int(start), last = min(source - 1, Int((end - 1e-9).rounded(.down)))
            let weights = (first...last).map { column -> Float in
                let covered = min(end, Double(column + 1)) - max(start, Double(column))
                return Float(covered / step)
            }
            return (first, weights)
        }
    }

    static func reduce(_ rgba: [Float], width: Int, height: Int,
                       to targetWidth: Int, _ targetHeight: Int) -> [Float] {
        guard targetWidth != width || targetHeight != height else { return rgba }
        let columns = taps(from: width, to: targetWidth)
        let rows = taps(from: height, to: targetHeight)
        var horizontal = [Float](repeating: 0, count: targetWidth * height * 4)
        rgba.withUnsafeBufferPointer { source in
            horizontal.withUnsafeMutableBufferPointer { target in
                let target = target
                concurrent(height) { y in
                    for (x, tap) in columns.enumerated() {
                        var sum = SIMD4<Float>(repeating: 0)
                        for (offset, weight) in tap.weights.enumerated() {
                            let i = (y * width + tap.first + offset) * 4
                            sum += SIMD4(source[i], source[i + 1], source[i + 2], source[i + 3])
                                * weight
                        }
                        let o = (y * targetWidth + x) * 4
                        target[o] = sum.x; target[o + 1] = sum.y
                        target[o + 2] = sum.z; target[o + 3] = sum.w
                    }
                }
            }
        }
        var output = [Float](repeating: 0, count: targetWidth * targetHeight * 4)
        horizontal.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                let target = target
                concurrent(targetHeight) { y in
                    let tap = rows[y]
                    for x in 0..<targetWidth {
                        var sum = SIMD4<Float>(repeating: 0)
                        for (offset, weight) in tap.weights.enumerated() {
                            let i = ((tap.first + offset) * targetWidth + x) * 4
                            sum += SIMD4(source[i], source[i + 1], source[i + 2], source[i + 3])
                                * weight
                        }
                        let o = (y * targetWidth + x) * 4
                        target[o] = sum.x; target[o + 1] = sum.y
                        target[o + 2] = sum.z; target[o + 3] = sum.w
                    }
                }
            }
        }
        return output
    }

    private static func concurrent(_ iterations: Int, _ body: (Int) -> Void) {
        #if canImport(Dispatch)
        DispatchQueue.concurrentPerform(iterations: iterations, execute: body)
        #else
        for index in 0..<iterations { body(index) }
        #endif
    }
}
