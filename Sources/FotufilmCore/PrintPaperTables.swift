import Foundation

/// Analytic example output media. Commercial receiver calibrations are not bundled.
extension PrintPaper {
    var dyes: [[Float]] { SpectralGrid.paperDyes }
    var sensitivity: [[Float]] {
        isScan ? SpectralGrid.labScanSensitivity : SpectralGrid.paperSensitivity
    }

    func printCurve(for stock: FilmStock) -> CharacteristicCurve {
        printCurves(for: stock)[1]
    }

    func printCurves(for stock: FilmStock) -> [CharacteristicCurve] {
        let curve: CharacteristicCurve
        if stock.isReversal || self == .screen || self == .negative {
            curve = stock.paperCurve
        } else {
            // Simple, distinct contrast variants, not commercial calibrations.
            let gamma: Float
            switch self {
            case .enduraPremier: gamma = 2.8
            case .crystalArchive: gamma = 2.2
            case .vision2383: gamma = 3
            case .vision2393: gamma = 3.5
            case .eternaCP: gamma = 2.7
            default: gamma = 2.5
            }
            curve = CharacteristicCurve(dMin: 0.05, gamma: gamma,
                toe: -0.5, toeWidth: 0.15, shoulder: 0.5, shoulderWidth: 0.15)
        }
        return [curve, curve, curve]
    }

    /// The fixed lab-scan profile `isReferenceAnchored` names: the reference negative's
    /// log10(red/green, blue/green) read at mid-grey through the scan's bands, its solved printing
    /// balance on that medium, and the largest cast magnitude, in log paper exposure, that the
    /// machine's per-frame colour pass hands through before pulling a stock back toward the
    /// reference. A neutral reference and a zero ceiling make `referenceCastOffset` inert here, so
    /// every stock scans neutral; a calibrated build commits the numbers that
    /// `fotufilm --dump-labscan-reference <stock>` prints for its reference stock.
    static let labScanReferenceMidRatio = SIMD2<Float>(0, 0)
    static let labScanReferenceBalance: [Float] = [1, 1, 1]
    static let labScanCastCeiling: Float = 0
}

extension SpectralGrid {
    static let labScanSensitivity = normalizeSensitivities(
        [Float(630), 540, 450].map { center in
            wavelengths.map { exp(-0.5 * pow(($0 - center) / 15, 2)) }
        })
}
