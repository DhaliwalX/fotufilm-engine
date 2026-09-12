import Foundation

/// A returned/direct exposure ratio, before the amount and spectrum controls.
public enum HalationReturn {
    public static let range: ClosedRange<Float> = 0...1

    public static func validate(_ ratio: Float) throws {
        guard ratio.isFinite, range.contains(ratio) else {
            throw TransportError.invalid("halation return must be a finite ratio from 0 through 1")
        }
    }

    /// Preserve the stock's record balance while setting its red reference ratio.
    public static func ratios(for stock: FilmStock, overriding ratio: Float?) throws -> [Float] {
        guard let ratio else { return stock.halationStrength }
        try validate(ratio)
        if ratio == 0 { return stock.halationStrength.map { _ in 0 } }
        guard let red = stock.halationStrength.first, red.isFinite, red > 0 else {
            throw TransportError.unsupported("a halation return override requires a positive red reference")
        }
        return stock.halationStrength.map { ($0 / red) * ratio }
    }

    /// A spectral construction uses the arithmetic mean of its red ratios as its reference.
    /// Scaling every wavelength and receiver together retains the supplied spectral balance.
    static func applying(_ ratio: Float?, to supplied: LayeredTransport) throws -> LayeredTransport {
        guard let ratio else { return supplied }
        try validate(ratio)
        try supplied.validate()
        var model = supplied
        if ratio == 0 {
            model.returnedToDirect = model.returnedToDirect.map { $0.map { _ in 0 } }
            return model
        }
        let red = model.returnedToDirect[0]
        let reference = red.reduce(0, +) / Double(red.count)
        guard reference > 0 else {
            throw TransportError.unsupported("a halation return override requires a positive red reference")
        }
        model.returnedToDirect = model.returnedToDirect.map { row in
            row.map { ($0 / reference) * Double(ratio) }
        }
        return model
    }
}
