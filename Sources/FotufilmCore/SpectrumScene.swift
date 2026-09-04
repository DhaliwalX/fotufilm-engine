import Foundation

/// Shared test scene containing a hue sweep, neutral ramp, and hue/saturation wheel on black.
/// Mid-grey is 0.18, the sweep peaks 1.5 stops above it, and the ramp reaches 2 stops above it.
/// The hue zones expose cross-layer coupler changes; the neutral ramp verifies grey-axis anchoring.
/// Zone responses do not isolate individual interlayer barriers because the matrix is re-anchored
/// after each change.
public struct SpectrumScene {

    /// Which part of the scene a pixel belongs to.
    public enum Zone: Int, CaseIterable, Sendable {
        /// The three thirds of the hue sweep, named for the two layers that trade places across
        /// each. A name for what is drawn there, not a claim about which control it reports on.
        case redGreen, greenBlue, redBlue
        /// The brightness ramp — the anchor's control zone.
        case neutral
        /// The wheel, which mixes every hue and saturation and so belongs to no single pairing.
        case wheel
        /// The black surround.
        case background

        public var label: String {
            switch self {
            case .redGreen: return "Red–Green"
            case .greenBlue: return "Green–Blue"
            case .redBlue: return "Red–Blue"
            case .neutral: return "Neutral"
            case .wheel: return "Wheel"
            case .background: return "Surround"
            }
        }
    }

    public let width: Int
    public let height: Int
    /// Scene-linear RGB, as the emulsion is shown it.
    public let image: ImageBuffer
    /// What each pixel belongs to, so a difference can be reported where it means something.
    public let zones: [Zone]

    /// The three thirds of the sweep, which are the parts of the scene the coupler controls are
    /// being demonstrated on. `neutral` is the control and the rest is scenery.
    public static let colourZones: [Zone] = [.redGreen, .greenBlue, .redBlue]

    /// Everything but the black surround, which is four fifths of the frame and where by
    /// construction nothing can happen. A whole-frame mean is that emptiness, not the picture.
    public static let litZones: [Zone] =
        Zone.allCases.filter { $0 != .background }

    /// Mid grey, and the level every other element is placed against.
    public static let mid: Float = 0.18

    /// The size the app's Film Model screen develops this at — half the browser demo's, same
    /// proportions. Named here so the tests measure the picture the user is actually shown rather
    /// than a number kept in step by hand.
    public static let previewSize = (width: 512, height: 342)

    /// Returns a full-saturation hue from three squared raised-cosine lobes.
    /// The lobes have no channel-crossing corners and sum to 9/8 at every angle.
    public static func hue(_ degrees: Float) -> (Float, Float, Float) {
        func lobe(_ center: Float) -> Float {
            let c = (1 + cos((degrees - center) * .pi / 180)) / 2
            return c * c
        }
        return (lobe(0), lobe(120), lobe(240))
    }

    /// Builds the scene using proportional geometry. The black gap between sweep and ramp exposes
    /// flare as a nonzero lift.
    public static func make(width: Int, height: Int) -> SpectrumScene {
        precondition(width > 0 && height > 0)
        var buffer = ImageBuffer(width: width, height: height)
        var zones = [Zone](repeating: .background, count: width * height)

        func put(_ x: Int, _ y: Int, _ r: Float, _ g: Float, _ b: Float, _ zone: Zone) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let i = y * width + x
            buffer.planes[0][i] = r
            buffer.planes[1][i] = g
            buffer.planes[2][i] = b
            zones[i] = zone
        }

        let w = Float(width), h = Float(height)
        let left = Int(0.06 * w), right = Int(0.62 * w)
        let sweepTop = Int(0.26 * h), sweepBottom = Int(0.32 * h)
        let rampTop = Int(0.62 * h), rampBottom = Int(0.70 * h)
        let center = (x: 0.80 * w, y: 0.48 * h)
        let radius = 0.16 * w
        guard right > left, sweepBottom > sweepTop, rampBottom > rampTop else {
            return SpectrumScene(width: width, height: height,
                                 image: buffer, zones: zones)
        }

        let sweepPeak = mid * pow(2, 1.5)
        for x in left..<right {
            let degrees = Float(x - left) / Float(right - left) * 360
            let (r, g, b) = hue(degrees)
            let zone = arc(at: degrees)
            for y in sweepTop..<sweepBottom {
                put(x, y, r * sweepPeak, g * sweepPeak, b * sweepPeak, zone)
            }
        }

        let rampTopLevel = mid * pow(2, 2)
        for x in left..<right {
            let v = Float(x - left) / Float(right - left - 1) * rampTopLevel
            for y in rampTop..<rampBottom { put(x, y, v, v, v, .neutral) }
        }

        // A stop over mid grey. At the exposure the sweep sits at, the wheel's white centre rides
        // the paper's shoulder and prints as a flat disc with no chroma left in it.
        let wheelPeak = mid * pow(2, 1)
        for y in Int(center.y - radius - 1)...Int(center.y + radius + 1) {
            for x in Int(center.x - radius - 1)...Int(center.x + radius + 1) {
                let dx = Float(x) - center.x, dy = Float(y) - center.y
                let distance = (dx * dx + dy * dy).squareRoot()
                // One pixel of coverage at the rim, so the disc has an edge rather than a
                // staircase.
                let coverage = clamp(radius - distance + 0.5, 0, 1)
                if coverage <= 0 { continue }
                let saturation = clamp(distance / radius, 0, 1)
                let (r, g, b) = hue(atan2(dy, dx) * 180 / .pi)
                let k = wheelPeak * coverage
                put(x, y, (1 - saturation + saturation * r) * k,
                    (1 - saturation + saturation * g) * k,
                    (1 - saturation + saturation * b) * k, .wheel)
            }
        }

        return SpectrumScene(width: width, height: height,
                             image: buffer, zones: zones)
    }

    /// Which pairing the sweep is walking at this angle. The lobes peak 120° apart, so each third
    /// has one layer at its floor and the other two trading places.
    public static func arc(at degrees: Float) -> Zone {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        switch positive {
        case ..<120: return .redGreen
        case ..<240: return .greenBlue
        default: return .redBlue
        }
    }

    /// The scene as interleaved RGBA floats, which is what the Metal renderer reads.
    public func interleavedRGBA() -> [Float] {
        var out = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            out[i * 4] = image.planes[0][i]
            out[i * 4 + 1] = image.planes[1][i]
            out[i * 4 + 2] = image.planes[2][i]
        }
        return out
    }

    /// The pixel indices belonging to one zone, for reporting a difference per zone.
    public func indices(of zone: Zone) -> [Int] {
        zones.indices.filter { zones[$0] == zone }
    }
}
