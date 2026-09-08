#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Scene-light controls: positive warmth lowers Kelvin, positive tint adds green light.
enum UndertoneAxis {
    static let neutral =
        Double(WhiteBalance.kelvinToMired(WhiteBalance.neutralKelvin))
    static let cool = 1e6 / 12000.0
    static let warm = 1e6 / 2500.0

    static func warmth(fromMired mired: Double) -> Double {
        let warmth = mired >= neutral
            ? (mired - neutral) / (warm - neutral)
            : (mired - neutral) / (neutral - cool)
        return min(max(warmth, -1), 1)
    }

    static func mired(fromWarmth warmth: Double) -> Double {
        warmth > 0
            ? neutral + warmth * (warm - neutral)
            : neutral + warmth * (neutral - cool)
    }

    /// The pad and spectral illuminant use the same green-positive sign.
    static func padTint(fromDuv tint: Double) -> Double {
        min(max(tint / 100, -1), 1)
    }

    static func duv(fromPadTint value: Double) -> Double {
        value * 100
    }
}
