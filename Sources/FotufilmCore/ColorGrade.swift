import Foundation

/// Three-way colour correction applied to the finished print.
public struct ColorGrade: Equatable, Sendable, Codable {
    /// One band's three numbers, all resting at zero.
    public struct Band: Equatable, Sendable, Codable {
        /// -1 cool … +1 warm.
        public var balanceX: Float = 0
        /// -1 magenta … +1 green.
        public var balanceY: Float = 0
        /// -1 down … +1 up.
        public var level: Float = 0

        public init(balanceX: Float = 0, balanceY: Float = 0, level: Float = 0) {
            self.balanceX = balanceX
            self.balanceY = balanceY
            self.level = level
        }

        public var isNeutral: Bool {
            balanceX == 0 && balanceY == 0 && level == 0
        }

        /// Written out rather than synthesised, so an absent number is the resting one instead of a
        /// thrown error — the same forgiveness the stored edit as a whole is decoded with.
        private enum CodingKeys: String, CodingKey {
            case balanceX, balanceY, level
        }

        public init(from decoder: Decoder) throws {
            self.init()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            balanceX = try c.decodeIfPresent(Float.self, forKey: .balanceX) ?? 0
            balanceY = try c.decodeIfPresent(Float.self, forKey: .balanceY) ?? 0
            level = try c.decodeIfPresent(Float.self, forKey: .level) ?? 0
        }

        /// The band's channel tilt: what its pad asks each channel to do,
        /// before the band's own scaling.
        var tilt: SIMD3<Float> {
            let x = min(max(balanceX, -1), 1)
            let y = min(max(balanceY, -1), 1)
            let warm = SIMD3<Float>(1, 0, -1)
            let green = SIMD3<Float>(-0.5, 1, -0.5)
            return x * warm + y * green
        }

        var clampedLevel: Float { min(max(level, -1), 1) }
    }

    public var shadows = Band()
    public var midtones = Band()
    public var highlights = Band()

    public init(shadows: Band = Band(), midtones: Band = Band(),
                highlights: Band = Band()) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
    }

    public static let neutral = ColorGrade()

    /// Missing bands decode to their neutral values for backward compatibility.
    private enum CodingKeys: String, CodingKey {
        case shadows, midtones, highlights
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try c.decodeIfPresent(Band.self, forKey: .shadows) ?? Band()
        midtones = try c.decodeIfPresent(Band.self, forKey: .midtones) ?? Band()
        highlights = try c.decodeIfPresent(Band.self, forKey: .highlights)
            ?? Band()
    }

    /// True when the grade would leave the print exactly as it found it.
    public var isNeutral: Bool {
        shadows.isNeutral && midtones.isNeutral && highlights.isNeutral
    }

    /// Lift at full shadow travel, as a fraction of paper white.
    static let shadowLift: Float = 0.04
    /// Colour in the shadows is half the reach of level.
    static let shadowTilt: Float = 0.02
    /// Midtone gamma at full travel, in stops of the exponent: 2^-0.5, so the middle of the scale
    /// opens by about a third and closes by a quarter.
    static let midtoneGamma: Float = 0.5
    static let midtoneTilt: Float = 0.3
    /// Highlight gain at full travel, in stops: 2^0.6, a little over half a stop on white.
    static let highlightGain: Float = 0.6
    static let highlightTilt: Float = 0.3

    /// Per-channel lift: the value black is carried to.
    public var lift: SIMD3<Float> {
        SIMD3(repeating: Self.shadowLift * shadows.clampedLevel)
            + Self.shadowTilt * shadows.tilt
    }

    /// Per-channel gain: the multiplier white is carried by.
    public var gain: SIMD3<Float> {
        exp2(SIMD3(repeating: Self.highlightGain * highlights.clampedLevel)
             + Self.highlightTilt * highlights.tilt)
    }

    /// Per-channel *inverse* gamma — the exponent the engine actually raises
    /// by, so the kernel needs no division.
    public var inverseGamma: SIMD3<Float> {
        exp2(-(SIMD3(repeating: Self.midtoneGamma * midtones.clampedLevel)
               + Self.midtoneTilt * midtones.tilt))
    }

    /// The nine floats the packed engine configuration carries, in the order
    /// FOTUFILM_CONFIG_GRADE_LIFT, _GAIN and _INV_GAMMA expect.
    var packed: [Float] {
        let lift = self.lift, gain = self.gain, inverseGamma = self.inverseGamma
        return [lift.x, lift.y, lift.z,
                gain.x, gain.y, gain.z,
                inverseGamma.x, inverseGamma.y, inverseGamma.z]
    }

    /// Which signal the three-way corrector works on.
    public enum Space: String, Sendable, Codable {
        /// Display-linear light, as this engine has always graded.
        case linear
        /// The sRGB-encoded signal, where a grading suite's three-way corrector works. The encode is
        /// the grading space rather than the output transfer, so an SDR and an HDR print of the same
        /// edit still grade alike, and the print's own shoulder still finishes both.
        /// See `ColorScience.gradingEncode` for why the curve continues above white instead of
        /// clamping there.
        case encoded
    }

    /// The grade applied to one display-linear print value, in and out, matching `color_grade` in
    /// FotufilmHalideShared.h expression for expression.
    public func apply(_ value: SIMD3<Float>,
                      in space: Space = .linear) -> SIMD3<Float> {
        let lift = self.lift, gain = self.gain, exponent = self.inverseGamma
        var result = SIMD3<Float>()
        for channel in 0..<3 {
            let working = space == .encoded
                ? ColorScience.gradingEncode(value[channel]) : value[channel]
            let lifted = working * (gain[channel] - lift[channel])
                + lift[channel]
            let graded = exponent[channel] == 1
                ? lifted : pow(max(lifted, 0), exponent[channel])
            result[channel] = space == .encoded
                ? ColorScience.gradingDecode(graded) : graded
        }
        return result
    }
}

/// Element-wise 2^x.
private func exp2(_ value: SIMD3<Float>) -> SIMD3<Float> {
    // The scalar overload, picked by argument type — a `Float` cannot become a `SIMD3`, so this
    // does not recur. Naming the module instead would reach past the single-precision `exp2`
    // Android's Foundation does not carry.
    SIMD3(exp2(value.x), exp2(value.y), exp2(value.z))
}
