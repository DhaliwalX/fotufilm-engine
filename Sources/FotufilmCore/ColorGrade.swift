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
    /// The finished print's output levels, as fractions of the sRGB-encoded signal: where black
    /// and white land after the rest of the grade, whatever the output medium. Raising the black
    /// point fades black to a grey and lowering the white point dims white, with nothing clipped.
    /// Between them the print is rescaled in the grade's own space: display-linear light by
    /// default, or the encoded signal, where they act exactly as a grading suite's output levels.
    public var blackPoint: Float = 0
    public var whitePoint: Float = 1

    public init(shadows: Band = Band(), midtones: Band = Band(),
                highlights: Band = Band(), blackPoint: Float = 0, whitePoint: Float = 1) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
    }

    private enum CodingKeys: String, CodingKey {
        case shadows, midtones, highlights, blackPoint, whitePoint
    }

    /// Grades saved before the output levels existed decode with them at rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try container.decode(Band.self, forKey: .shadows)
        midtones = try container.decode(Band.self, forKey: .midtones)
        highlights = try container.decode(Band.self, forKey: .highlights)
        blackPoint = try container.decodeIfPresent(Float.self, forKey: .blackPoint) ?? 0
        whitePoint = try container.decodeIfPresent(Float.self, forKey: .whitePoint) ?? 1
    }

    public static let neutral = ColorGrade()

    /// True when the grade would leave the print exactly as it found it.
    public var isNeutral: Bool {
        shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && levelsAtRest
    }

    /// The range each output level moves over; the two meet at mid-scale.
    public static let blackPointRange: ClosedRange<Float> = 0...0.5
    public static let whitePointRange: ClosedRange<Float> = 0.5...1

    var levelsAtRest: Bool { clampedBlackPoint == 0 && clampedWhitePoint == 1 }

    var clampedBlackPoint: Float {
        blackPoint.isFinite
            ? min(max(blackPoint, Self.blackPointRange.lowerBound), Self.blackPointRange.upperBound) : 0
    }

    var clampedWhitePoint: Float {
        whitePoint.isFinite
            ? min(max(whitePoint, Self.whitePointRange.lowerBound), Self.whitePointRange.upperBound) : 1
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

    /// The lift and gain the kernel works with in `space`, the output levels folded in. The
    /// kernel raises `lifted = working · (gain − lift) + lift` by the inverse gamma, so the
    /// levels go in before the power, each at its own root: the band-free black then lands on
    /// the black point and white on the white point exactly, at any midtone setting, and the
    /// kernel needs nothing new. At rest they are the grade's own lift and gain, bit for bit.
    func levelled(in space: Space) -> (lift: SIMD3<Float>, gain: SIMD3<Float>) {
        let lift = self.lift, gain = self.gain
        guard !levelsAtRest else { return (lift, gain) }
        let exponent = inverseGamma
        func working(_ encoded: Float) -> Float {
            space == .encoded ? encoded : ColorScience.gradingDecode(encoded)
        }
        let black = working(clampedBlackPoint), white = working(clampedWhitePoint)
        var levelledLift = SIMD3<Float>(), levelledGain = SIMD3<Float>()
        for channel in 0..<3 {
            let root = 1 / exponent[channel]
            let low = pow(black, root), high = pow(white, root)
            levelledLift[channel] = low + (high - low) * lift[channel]
            levelledGain[channel] = low + (high - low) * gain[channel]
        }
        return (levelledLift, levelledGain)
    }

    /// The nine floats the packed engine configuration carries, in the order
    /// FOTUFILM_CONFIG_GRADE_LIFT, _GAIN and _INV_GAMMA expect, for a kernel grading in `space`.
    func packed(in space: Space) -> [Float] {
        let (lift, gain) = levelled(in: space), inverseGamma = self.inverseGamma
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
    /// FotufilmHalide/Stages/Transfer.h expression for expression.
    public func apply(_ value: SIMD3<Float>,
                      in space: Space = .linear) -> SIMD3<Float> {
        let (lift, gain) = levelled(in: space), exponent = self.inverseGamma
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
