#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The undertone's two axes over the edit's illuminant — reversed convention and all: dragging warm
/// declares a cool illuminant, and the adaptation warms the picture.
///
/// It lives in the shared layer rather than beside the controls that drive it because the control
/// catalogue reaches it too, and the catalogue is read by targets that never build the UIKit editor.
enum UndertoneAxis {
    static let neutral =
        Double(WhiteBalance.kelvinToMired(WhiteBalance.neutralKelvin))
    static let cool = 1e6 / 12000.0
    static let warm = 1e6 / 2500.0

    static func warmth(fromMired mired: Double) -> Double {
        let warmth = mired <= neutral
            ? (neutral - mired) / (neutral - cool)
            : (neutral - mired) / (warm - neutral)
        return min(max(warmth, -1), 1)
    }

    static func mired(fromWarmth warmth: Double) -> Double {
        warmth > 0
            ? neutral - warmth * (neutral - cool)
            : neutral - warmth * (warm - neutral)
    }

    /// The pad speaks in −1…1 with positive green; the edit stores Duv units with the illuminant's
    /// sign, so the axis reverses on the way through — declaring a magenta illuminant is what turns
    /// the picture green.
    static func padTint(fromDuv tint: Double) -> Double {
        min(max(-tint / 100, -1), 1)
    }

    static func duv(fromPadTint value: Double) -> Double {
        -value * 100
    }
}
