import Foundation

/// Synthetic three-layer receiver on the 380...780 nm grid at 10 nm intervals.
/// These analytic curves are illustrative, not measurements of a commercial paper.
enum PrintPaperSpectra {
    static let neutralAmounts: [Float] = [1, 1, 1]
    static let dyeDensity: [[Float]] = bands(width: 50)
    static let layerSensitivity: [[Float]] = bands(width: 35)

    private static func bands(width: Float) -> [[Float]] {
        [Float(650), 550, 450].map { center in
            (0..<41).map { index in
                let wavelength = Float(380 + index * 10)
                return exp(-0.5 * pow((wavelength - center) / width, 2))
            }
        }
    }
}
