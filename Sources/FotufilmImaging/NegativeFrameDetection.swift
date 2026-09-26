import CoreGraphics
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Finds the exposed picture on a scanned negative: the band of columns and rows that carry an
/// image, between the clear film of the rebate, sprocket holes brighter than the base, and a
/// holder too dense to be film.
public enum NegativeFrameDetection {
    /// Density over the base below which film reads as clear.
    static let clearDensity: Float = 0.1
    /// Density above which the scan sees the holder rather than film.
    static let opaqueDensity: Float = 2.6
    /// The share of a column or row that must be picture for it to belong to the frame.
    static let pictureShare: Float = 0.3

    /// The picture's area as a unit rectangle from the top left of `scan`, which holds linear
    /// transmission read against `border`. Nil when the picture already fills the scan or no
    /// frame stands out.
    public static func imageArea(of scan: ImageBuffer, border: SIMD3<Float>) -> CGRect? {
        let w = scan.width, h = scan.height
        guard w >= 16, h >= 16, border.x > 0, border.y > 0, border.z > 0 else { return nil }
        var picture = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            var density: Float = 0
            var valid = true
            for c in 0..<3 {
                let sample = scan.planes[c][i]
                guard sample.isFinite, sample > 0 else { valid = false; break }
                density -= log10(sample / border[c])
            }
            density /= 3
            picture[i] = valid && density > clearDensity && density < opaqueDensity
        }

        let columns = (0..<w).map { x in
            share((0..<h).lazy.filter { picture[$0 * w + x] }.count, of: h)
        }
        guard let across = longestRun(smoothed(columns)) else { return nil }
        let rows = (0..<h).map { y in
            share(across.lazy.filter { picture[y * w + $0] }.count, of: across.count)
        }
        guard let down = longestRun(smoothed(rows)) else { return nil }

        // A pixel in from each edge, off the soft step between rebate and picture.
        let x0 = Double(across.lowerBound + 1) / Double(w)
        let x1 = Double(across.upperBound - 1) / Double(w)
        let y0 = Double(down.lowerBound + 1) / Double(h)
        let y1 = Double(down.upperBound - 1) / Double(h)
        let area = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard area.width >= 0.25, area.height >= 0.25,
              area.width < 0.98 || area.height < 0.98 else { return nil }
        return area
    }

    private static func share(_ count: Int, of total: Int) -> Float {
        total > 0 ? Float(count) / Float(total) : 0
    }

    /// A three-tap average, so a line of edge lettering or a scratch does not split the frame.
    private static func smoothed(_ values: [Float]) -> [Float] {
        values.indices.map { i in
            let near = values[max(0, i - 1)...min(values.count - 1, i + 1)]
            return near.reduce(0, +) / Float(near.count)
        }
    }

    private static func longestRun(_ shares: [Float]) -> Range<Int>? {
        var best: Range<Int>?
        var start: Int?
        // A trailing zero closes a run that reaches the last column.
        for (i, value) in (shares + [0]).enumerated() {
            if value >= pictureShare {
                if start == nil { start = i }
            } else if let begun = start {
                if (best?.count ?? 0) < i - begun { best = begun..<i }
                start = nil
            }
        }
        return best
    }
}
