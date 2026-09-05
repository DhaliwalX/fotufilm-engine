import Foundation

/// One handle of a hand-drawn spectral curve: a wavelength, and the level the curve passes
/// through there.
public struct SpectralControlPoint: Codable, Equatable, Sendable {
    public var nm: Float
    public var value: Float

    public init(nm: Float, value: Float) {
        self.nm = nm
        self.value = value
    }
}

/// A hand-drawn spectral curve: the handles an author placed on one side, the full-grid record the
/// engine renders from on the other, and the two conversions between them.
public enum SpectralCurve {
    /// The drawn curve on the engine's own grid.
    ///
    /// Monotone cubic (Fritsch–Carlson) between the handles: the curve passes through every handle
    /// and never overshoots between two of them, so a lobe drawn down to zero sits at zero rather
    /// than dipping under it. Outside the outermost handles the curve holds their value, which is
    /// the only continuation that does not invent a trend the author never drew.
    public static func resampled(_ points: [SpectralControlPoint]) -> [Float] {
        let sorted = points.sorted { $0.nm < $1.nm }
        guard let first = sorted.first else {
            return [Float](repeating: 0, count: SpectralGrid.count)
        }
        guard sorted.count > 1 else {
            return [Float](repeating: max(first.value, 0), count: SpectralGrid.count)
        }

        // Two handles on the same wavelength describe a step no smooth curve has; the later one
        // wins, which is also what dragging one handle onto another appears as.
        var xs: [Float] = [], ys: [Float] = []
        for point in sorted {
            if let last = xs.last, point.nm - last < 0.5 {
                ys[ys.count - 1] = point.value
            } else {
                xs.append(point.nm)
                ys.append(point.value)
            }
        }
        guard xs.count > 1 else {
            return [Float](repeating: max(ys[0], 0), count: SpectralGrid.count)
        }

        let n = xs.count
        let h = (0..<(n - 1)).map { xs[$0 + 1] - xs[$0] }
        let delta = (0..<(n - 1)).map { (ys[$0 + 1] - ys[$0]) / h[$0] }

        // Fritsch–Carlson slopes: zero wherever the data turns, a weighted harmonic mean where it
        // does not, which is the condition that keeps every segment inside its endpoints.
        var slope = [Float](repeating: 0, count: n)
        slope[0] = delta[0]
        slope[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            if delta[i - 1] * delta[i] <= 0 {
                slope[i] = 0
            } else {
                let w1 = 2 * h[i] + h[i - 1]
                let w2 = h[i] + 2 * h[i - 1]
                slope[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
            }
        }

        var segment = 0
        return SpectralGrid.wavelengths.map { wavelength in
            if wavelength <= xs[0] { return max(ys[0], 0) }
            if wavelength >= xs[n - 1] { return max(ys[n - 1], 0) }
            while wavelength > xs[segment + 1] { segment += 1 }
            let t = (wavelength - xs[segment]) / h[segment]
            let t2 = t * t, t3 = t2 * t
            let value = ys[segment] * (2 * t3 - 3 * t2 + 1)
                + slope[segment] * h[segment] * (t3 - 2 * t2 + t)
                + ys[segment + 1] * (-2 * t3 + 3 * t2)
                + slope[segment + 1] * h[segment] * (t3 - t2)
            return max(value, 0)
        }
    }

    /// Handles for a sampled row: few enough to drag, close enough that resampling them redraws
    /// the record.
    ///
    /// Ramer–Douglas–Peucker over the row, with the deviation read vertically and measured against
    /// the row's own peak — a record's absolute scale is a normalisation the engine discards, so a
    /// tolerance in absolute units would keep either every sample or none.
    /// The first and last samples always survive, so the curve keeps its full span.
    public static func controlPoints(from samples: [Float],
                                     tolerance: Float = 0.01) -> [SpectralControlPoint] {
        precondition(samples.count == SpectralGrid.count)
        let peak = max(samples.max() ?? 0, 1e-12)
        let scaled = samples.map { $0 / peak }
        var keep = [Bool](repeating: false, count: samples.count)
        keep[0] = true
        keep[samples.count - 1] = true

        func simplify(_ low: Int, _ high: Int) {
            guard high > low + 1 else { return }
            let span = Float(high - low)
            var worst = low
            var worstDistance: Float = 0
            for i in (low + 1)..<high {
                let t = Float(i - low) / span
                let line = scaled[low] + t * (scaled[high] - scaled[low])
                let distance = abs(scaled[i] - line)
                if distance > worstDistance {
                    worstDistance = distance
                    worst = i
                }
            }
            guard worstDistance > tolerance else { return }
            keep[worst] = true
            simplify(low, worst)
            simplify(worst, high)
        }
        simplify(0, samples.count - 1)

        return samples.indices.filter { keep[$0] }.map {
            SpectralControlPoint(nm: SpectralGrid.wavelengths[$0], value: samples[$0])
        }
    }
}

public extension SpectralGrid {
    /// The dye record the engine builds for one of its published process families — what a
    /// generated stock renders through, and the rows a drawn dye curve starts from.
    static func familyDyeDensities(_ family: FilmDyeFamily) -> [[Float]] {
        dyes(family: family)
    }

    /// Rescales three dye density rows so the three sum to one at every wavelength, which is the
    /// form the engine consumes. Rows already in that form pass through unchanged, so applying it
    /// after every edit costs nothing but the constraint.
    static func partitionedDyes(_ densities: [[Float]]) -> [[Float]] {
        partition(densities)
    }
}
