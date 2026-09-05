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
            case .photoContrast: gamma = 2.8
            case .photoSoft: gamma = 2.2
            case .projection: gamma = 3
            case .projectionContrast: gamma = 3.5
            case .projectionSoft: gamma = 2.7
            default: gamma = 2.5
            }
            curve = CharacteristicCurve(dMin: 0.05, gamma: gamma,
                toe: -0.5, toeWidth: 0.15, shoulder: 0.5, shoulderWidth: 0.15)
        }
        return [curve, curve, curve]
    }
}

extension SpectralGrid {
    static let labScanSensitivity = normalizeSensitivities(
        [Float(630), 540, 450].map { center in
            wavelengths.map { exp(-0.5 * pow(($0 - center) / 15, 2)) }
        })
}
