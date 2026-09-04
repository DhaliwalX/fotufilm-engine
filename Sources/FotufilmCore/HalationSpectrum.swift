import Foundation

/// Wavelength-dependent gain applied to the stock's halation return spectrum. Handles use stops
/// because masked negatives can differ by roughly 60× between records. A neutral curve leaves the
/// measured return unchanged. This gain cannot create energy in a zero-return record;
/// `halationSourceColour` controls interpolation toward the source-light balance.
public enum HalationSpectrum {
    /// Editor handle wavelengths at 50 nm intervals, including the 450, 550, and 650 nm record
    /// centres.
    public static let handleNM: [Float] = [400, 450, 500, 550, 600, 650, 700]

    /// Where a handle rests: no stops added, which is the film's own return trip.
    public static let neutralStops: Float = 0

    /// Handle range in stops. ±6 covers the measured record ratios in bundled masked negatives.
    public static let travelStops: ClosedRange<Float> = -6...6

    /// Every handle at rest.
    public static var neutral: [Float] {
        [Float](repeating: neutralStops, count: handleNM.count)
    }

    /// Whether these handles say nothing the film does not already say.
    public static func isNeutral(_ handles: [Float]) -> Bool {
        guard handles.count == handleNM.count else { return true }
        return handles.allSatisfy { abs($0 - neutralStops) < 1e-4 }
    }

    /// Resamples handles onto the 41-band grid and returns linear gain, or an empty array for a
    /// neutral curve. Interpolation occurs in stops before exponentiation. A constant offset keeps
    /// negative stop values above `SpectralCurve`'s zero floor without changing the fitted shape.
    public static func resampled(_ handles: [Float]) -> [Float] {
        guard handles.count == handleNM.count, !isNeutral(handles) else { return [] }
        let floor = travelStops.lowerBound
        let points = zip(handleNM, handles).map { nm, stops in
            SpectralControlPoint(
                nm: nm,
                value: min(max(stops, floor), travelStops.upperBound) - floor)
        }
        return SpectralCurve.resampled(points).map { exp2($0 + floor) }
    }

    /// Reduces spectral gain to one factor per record using
    /// `sum(illuminant × sensitivity × gain) / sum(illuminant × sensitivity)`. `sensitivity` must
    /// contain 41-band spectral rows, not the legacy 3×3 matrix. Invalid or zero-weight input
    /// returns a factor of 1.
    public static func recordGain(spectrum: [Float], sensitivity: [[Float]],
                                  illuminant: [Float] = SpectralGrid.d65) -> [Float] {
        let rest = [Float](repeating: 1, count: sensitivity.count)
        guard spectrum.count == SpectralGrid.count,
              illuminant.count == SpectralGrid.count else { return rest }

        return sensitivity.map { record in
            guard record.count == SpectralGrid.count else { return 1 }
            var weight: Float = 0, weighted: Float = 0
            for band in 0..<SpectralGrid.count {
                let w = max(illuminant[band], 0) * max(record[band], 0)
                weight += w
                weighted += w * max(spectrum[band], 0)
            }
            guard weight > 0 else { return 1 }
            return weighted / weight
        }
    }
}
