import Foundation

/// Kodak's Cineon printing-density encoding, as a film scanner writes it: each record's printing
/// density above the film base at 0.002 D per code value, with the base at code value 95 and
/// the 10-bit range ending at 1023. Code value 685, 1.18 D above the base, is the reference
/// white a normally exposed 90% card is expected near. The scan places nothing at either: each
/// code value is the density the film itself holds.
///
/// Values travel through the engine as the normalised signal `code value / 1023`, which is what
/// DaVinci Resolve's Cineon Film Log input and a 10-bit DPX's Cineon transfer expect.
public enum CineonLog {
    public static let densityPerCodeValue: Float = 0.002
    public static let baseCodeValue: Float = 95
    public static let whiteCodeValue: Float = 685
    public static let maximumCodeValue: Float = 1023

    /// The normalised signal for printing density above the film base. Not clipped: a float
    /// delivery keeps what a 10-bit file would clip at either end.
    public static func signal(densityAboveBase density: Float) -> Float {
        (baseCodeValue + density / densityPerCodeValue) / maximumCodeValue
    }

    /// Printing density above the film base for a normalised signal.
    public static func densityAboveBase(signal: Float) -> Float {
        (signal * maximumCodeValue - baseCodeValue) * densityPerCodeValue
    }

    /// The 10-bit code value a normalised signal is written as.
    public static func codeValue(signal: Float) -> UInt16 {
        UInt16(min(max((signal * maximumCodeValue).rounded(), 0), maximumCodeValue))
    }
}
