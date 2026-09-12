import Foundation

/// An illustrative optical colour enlarger, not a measured hardware calibration.
/// Lamp shape and M/Y filtration act on wavelengths before negative transmission.
/// Exposure is relative to the fixed 3200 K, M 0.40, Y 0.50 reference setup.
public struct PrinterProfile: Hashable, Codable, Sendable {
    public var lampKelvin: Float
    public var exposureEV: Float
    /// Synthetic optical-density strengths, not manufacturer filter-dial units.
    public var magenta: Float
    public var yellow: Float

    public static let simulatedTungsten = PrinterProfile()
    public static let lampRange: ClosedRange<Float> = 2800...3600
    public static let exposureRange: ClosedRange<Float> = -6...6
    public static let filterRange: ClosedRange<Float> = 0...1.2

    public init(lampKelvin: Float = 3200, exposureEV: Float = 0,
                magenta: Float = 0.4, yellow: Float = 0.5) {
        self.lampKelvin = lampKelvin
        self.exposureEV = exposureEV
        self.magenta = magenta
        self.yellow = yellow
    }

    /// Shared normalization for mutable API values and decoded profiles. Invalid values use
    /// the reference setup; finite values stay within this illustrative profile's domain.
    public var normalized: PrinterProfile {
        func held(_ value: Float, _ range: ClosedRange<Float>, _ fallback: Float) -> Float {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        return PrinterProfile(lampKelvin: held(lampKelvin, Self.lampRange, 3200),
                              exposureEV: held(exposureEV, Self.exposureRange, 0),
                              magenta: held(magenta, Self.filterRange, 0.4),
                              yellow: held(yellow, Self.filterRange, 0.5))
    }

    /// Relative radiant spectrum at 81 wavelengths, 380–780 nm in 5 nm steps.
    /// The bare lamp is normalized at 560 nm. Filtration is never renormalized.
    /// Exposure is omitted here and applied by Halide before the paper response.
    public var filteredSpectrum: [Float] {
        let p = normalized
        let lamp = Illuminant.planckian(kelvin: p.lampKelvin)
        return SpectralGrid.wavelengths.enumerated().map { i, wavelength in
            let m = exp(-0.5 * pow((wavelength - 550) / 45, 2))
            let y = 1 / (1 + exp((wavelength - 500) / 12))
            return lamp[i] * pow(10, -p.magenta * m - p.yellow * y)
        }
    }

    static func resolved(_ profile: PrinterProfile?, stock: FilmStock,
                         paper: PrintPaper) -> PrinterProfile? {
        Enlarger.illuminates(stock: stock, paper: paper) ? profile?.normalized : nil
    }

    /// Only spectral controls identify the printing LUT. Exposure changes configuration alone.
    var spectralSignature: UInt64 {
        let p = normalized
        var h: UInt64 = 0x5052494E54455201
        for value in [p.lampKelvin, p.magenta, p.yellow] {
            h = (h ^ UInt64(value.bitPattern)) &* 0x100000001b3
        }
        return h
    }
}
