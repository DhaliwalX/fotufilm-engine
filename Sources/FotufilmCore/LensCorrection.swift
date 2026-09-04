import Foundation

/// What a lens did to the picture, and therefore what has to be undone: the straight lines it bent,
/// the corners it dimmed, and the colours it failed to land on the same spot.
///
/// Every model here is written in the *forward* direction — given a radius in the corrected picture,
/// where on the original frame did that light actually fall. That is the direction a resampler wants
/// (for each output pixel, which input pixel to read), so nothing here ever has to be inverted.
///
/// Radius is normalised so that `1` is half the frame diagonal, which puts the corners at 1 and mid
/// frame-edge below it. Any profile imported from elsewhere must be converted into this convention
/// on the way in — see `LensProfile`.
public struct LensCorrection: Equatable, Sendable, Codable {
    /// How the lens bent straight lines.
    ///
    /// All three forms are the same degree-4 polynomial in `r` wearing different hats, so the engine
    /// only ever evaluates one expression. They are kept apart as cases because a profile records
    /// which one it was calibrated in, and rounding one into another loses that.
    public enum Distortion: Equatable, Sendable, Codable {
        case none
        /// `r_src = r · (1 - k₁ + k₁r²)`, the cubic that holds the corner fixed.
        case poly3(k1: Float)
        /// `r_src = r · (1 + k₁r² + k₂r⁴)`.
        case poly5(k1: Float, k2: Float)
        /// `r_src = r · (ar³ + br² + cr + (1 - a - b - c))`, the PTLens form.
        case ptLens(a: Float, b: Float, c: Float)

        /// The five coefficients of `r_src = r · (d + cr + br² + ar³ + er⁴)`, in that order, which is
        /// the one shape all of the above collapse to.
        var polynomial: (d: Float, c: Float, b: Float, a: Float, e: Float) {
            switch self {
            case .none:
                return (1, 0, 0, 0, 0)
            case .poly3(let k1):
                return (1 - k1, 0, k1, 0, 0)
            case .poly5(let k1, let k2):
                return (1, 0, k1, 0, k2)
            case .ptLens(let a, let b, let c):
                return (1 - a - b - c, c, b, a, 0)
            }
        }

        public var isIdentity: Bool {
            if case .none = self { return true }
            let p = polynomial
            return p.d == 1 && p.c == 0 && p.b == 0 && p.a == 0 && p.e == 0
        }

        /// Where the light for corrected radius `r` actually landed.
        public func sourceRadius(_ r: Float) -> Float {
            let p = polynomial
            return r * (p.d + r * (p.c + r * (p.b + r * (p.a + r * p.e))))
        }

        /// The same curve with only `fraction` of its strength, for an amount control. Interpolating
        /// the coefficients toward the identity is exact for every model here, because each is linear
        /// in its own coefficients once `r` is fixed.
        public func scaled(by fraction: Float) -> Distortion {
            switch self {
            case .none: return .none
            case .poly3(let k1): return .poly3(k1: k1 * fraction)
            case .poly5(let k1, let k2):
                return .poly5(k1: k1 * fraction, k2: k2 * fraction)
            case .ptLens(let a, let b, let c):
                return .ptLens(a: a * fraction, b: b * fraction, c: c * fraction)
            }
        }
    }

    /// How much light the lens lost toward the corners.
    public enum Vignetting: Equatable, Sendable, Codable {
        case none
        /// Transmission `V(r) = 1 + k₁r² + k₂r⁴ + k₃r⁶`, the even polynomial a measured falloff is
        /// normally recorded as. The coefficients are usually negative, the corners having received
        /// less light than the centre.
        case radial(k1: Float, k2: Float, k3: Float)
        /// The *gain* stated directly — `G(r) = 1 + k₀r² + k₁r⁴ + k₂r⁶ + k₃r⁸ + k₄r¹⁰` — which is
        /// how a file that carries its own correction puts it. Kept as its own case rather than
        /// inverted into a transmission, because inverting a polynomial is not a polynomial and
        /// fitting one to the result would lose accuracy the file had already paid for.
        case radialGain(k0: Float, k1: Float, k2: Float, k3: Float, k4: Float)

        public var isIdentity: Bool {
            switch self {
            case .none:
                return true
            case .radial(let a, let b, let c):
                return a == 0 && b == 0 && c == 0
            case .radialGain(let a, let b, let c, let d, let e):
                return a == 0 && b == 0 && c == 0 && d == 0 && e == 0
            }
        }

        /// The fraction of the light that survived to radius `r`.
        public func transmission(_ r: Float) -> Float {
            switch self {
            case .none:
                return 1
            case .radial(let k1, let k2, let k3):
                let r2 = r * r
                return 1 + r2 * (k1 + r2 * (k2 + r2 * k3))
            case .radialGain:
                return 1 / max(directGain(r), 1e-6)
            }
        }

        /// The gain a file stated outright, before it is clamped.
        private func directGain(_ r: Float) -> Float {
            guard case .radialGain(let k0, let k1, let k2, let k3,
                                   let k4) = self else { return 1 }
            let r2 = r * r
            return 1 + r2 * (k0 + r2 * (k1 + r2 * (k2 + r2 * (k3 + r2 * k4))))
        }

        /// What the picture has to be multiplied by to put that light back.
        ///
        /// Clamped, because a profile extrapolated past its calibrated radius can predict a
        /// transmission at or below zero, and dividing by that would hand the corners an infinity.
        /// The same ceiling holds a stated gain to something a photograph can survive.
        public func gain(_ r: Float) -> Float {
            switch self {
            case .none:
                return 1
            case .radial:
                return 1 / max(transmission(r), 0.05)
            case .radialGain:
                return min(max(directGain(r), 0.05), 20)
            }
        }

        public func scaled(by fraction: Float) -> Vignetting {
            switch self {
            case .none:
                return .none
            case .radial(let k1, let k2, let k3):
                return .radial(k1: k1 * fraction, k2: k2 * fraction,
                               k3: k3 * fraction)
            case .radialGain(let k0, let k1, let k2, let k3, let k4):
                return .radialGain(k0: k0 * fraction, k1: k1 * fraction,
                                   k2: k2 * fraction, k3: k3 * fraction,
                                   k4: k4 * fraction)
            }
        }
    }

    /// A radial scale factor stated as an even polynomial in radius — `k₀ + k₁r² + k₂r⁴ + k₃r⁶` —
    /// which is the shape a file's own warp uses.
    ///
    /// It is a *factor*, not a radius: the corrected point at radius r reads from `r · factor(r)`.
    /// The identity is `k₀ = 1` with the rest at zero.
    public struct EvenPolynomial: Equatable, Sendable, Codable {
        public var k0: Float
        public var k1: Float
        public var k2: Float
        public var k3: Float

        public init(k0: Float = 1, k1: Float = 0, k2: Float = 0,
                    k3: Float = 0) {
            self.k0 = k0
            self.k1 = k1
            self.k2 = k2
            self.k3 = k3
        }

        public static let identity = EvenPolynomial()

        public var isIdentity: Bool {
            k0 == 1 && k1 == 0 && k2 == 0 && k3 == 0
        }

        public func factor(_ r: Float) -> Float {
            let r2 = r * r
            return k0 + r2 * (k1 + r2 * (k2 + r2 * k3))
        }

        public func scaled(by fraction: Float) -> EvenPolynomial {
            EvenPolynomial(k0: 1 + (k0 - 1) * fraction, k1: k1 * fraction,
                           k2: k2 * fraction, k3: k3 * fraction)
        }
    }

    /// One warp per colour plane, which is how a file that carries its own correction states it.
    ///
    /// This replaces `distortion` and `lateralChroma` rather than joining them, because each plane's
    /// factor is measured against the *original* radius rather than against green's corrected one.
    /// Composing the two models instead would mean dividing one polynomial by another, and the
    /// result would no longer be a polynomial.
    public struct PlaneWarp: Equatable, Sendable, Codable {
        public var red: EvenPolynomial
        public var green: EvenPolynomial
        public var blue: EvenPolynomial

        public init(red: EvenPolynomial = .identity,
                    green: EvenPolynomial = .identity,
                    blue: EvenPolynomial = .identity) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public var isIdentity: Bool {
            red.isIdentity && green.isIdentity && blue.isIdentity
        }

        public func scaled(by fraction: Float) -> PlaneWarp {
            PlaneWarp(red: red.scaled(by: fraction),
                      green: green.scaled(by: fraction),
                      blue: blue.scaled(by: fraction))
        }
    }

    /// Lateral chromatic aberration: the lens focusing red and blue at slightly different
    /// magnifications, so edges toward the corners split into fringes. Green is the reference and is
    /// never moved.
    public enum LateralChroma: Equatable, Sendable, Codable {
        case none
        /// A flat magnification difference per channel — `r_src = r · k` — which is what most
        /// calibrations record.
        case linear(red: Float, blue: Float)
        /// `r_src = r · (br² + cr + v)` per channel, for lenses whose fringing does not grow
        /// linearly with radius.
        case poly3(red: Terms, blue: Terms)

        public struct Terms: Equatable, Sendable, Codable {
            public var b: Float
            public var c: Float
            public var v: Float
            public init(b: Float = 0, c: Float = 0, v: Float = 1) {
                self.b = b
                self.c = c
                self.v = v
            }
            func scale(_ r: Float) -> Float { v + r * (c + r * b) }
            /// Toward the identity `v = 1`, everything else vanishing.
            func scaled(by fraction: Float) -> Terms {
                Terms(b: b * fraction, c: c * fraction,
                      v: 1 + (v - 1) * fraction)
            }
        }

        public var isIdentity: Bool {
            switch self {
            case .none: return true
            case .linear(let red, let blue): return red == 1 && blue == 1
            case .poly3(let red, let blue):
                return red == Terms() && blue == Terms()
            }
        }

        /// The radius each channel has to be read from, given the corrected radius.
        public func sourceRadii(_ r: Float) -> (red: Float, blue: Float) {
            switch self {
            case .none:
                return (r, r)
            case .linear(let red, let blue):
                return (r * red, r * blue)
            case .poly3(let red, let blue):
                return (r * red.scale(r), r * blue.scale(r))
            }
        }

        public func scaled(by fraction: Float) -> LateralChroma {
            switch self {
            case .none:
                return .none
            case .linear(let red, let blue):
                return .linear(red: 1 + (red - 1) * fraction,
                               blue: 1 + (blue - 1) * fraction)
            case .poly3(let red, let blue):
                return .poly3(red: red.scaled(by: fraction),
                              blue: blue.scaled(by: fraction))
            }
        }
    }

    public var distortion: Distortion = .none
    public var vignetting: Vignetting = .none
    public var lateralChroma: LateralChroma = .none
    /// Set when the correction came from a file's own warp, in which case it says where all three
    /// planes read from and `distortion` and `lateralChroma` are left alone.
    public var planeWarp: PlaneWarp? = nil

    public init(distortion: Distortion = .none,
                vignetting: Vignetting = .none,
                lateralChroma: LateralChroma = .none,
                planeWarp: PlaneWarp? = nil) {
        self.distortion = distortion
        self.vignetting = vignetting
        self.lateralChroma = lateralChroma
        self.planeWarp = planeWarp
    }

    public static let none = LensCorrection()

    /// Whether applying this correction leaves the image unchanged.
    public var isIdentity: Bool {
        distortion.isIdentity && vignetting.isIdentity
            && lateralChroma.isIdentity && (planeWarp?.isIdentity ?? true)
    }

    public func scaled(by fraction: Float) -> LensCorrection {
        LensCorrection(distortion: distortion.scaled(by: fraction),
                       vignetting: vignetting.scaled(by: fraction),
                       lateralChroma: lateralChroma.scaled(by: fraction),
                       planeWarp: planeWarp?.scaled(by: fraction))
    }

    /// Where each channel's light for corrected radius `r` came from, and what the picture there has
    /// to be multiplied by.
    ///
    /// A plane warp answers for all three at once. Otherwise distortion moves the channels together
    /// and the chroma terms then part them.
    public func sample(atRadius r: Float)
        -> (red: Float, green: Float, blue: Float, gain: Float) {
        let moved = sourceRadii(red: r, green: r, blue: r)
        return (moved.red, moved.green, moved.blue, vignetting.gain(r))
    }

    /// Where each plane reads from, given the radius that plane has already arrived at.
    ///
    /// Taking three radii rather than one is what lets these compose: a stage after another is asked
    /// about the radii the stage before it reached, not about the radius the pixel started at.
    public func sourceRadii(red: Float, green: Float, blue: Float)
        -> (red: Float, green: Float, blue: Float) {
        if let planeWarp {
            return (red * planeWarp.red.factor(red),
                    green * planeWarp.green.factor(green),
                    blue * planeWarp.blue.factor(blue))
        }
        let moved = (red: distortion.sourceRadius(red),
                     green: distortion.sourceRadius(green),
                     blue: distortion.sourceRadius(blue))
        return (lateralChroma.sourceRadii(moved.red).red, moved.green,
                lateralChroma.sourceRadii(moved.blue).blue)
    }
}

/// One correction after another — a matched profile, then whatever the photographer dialled on top.
///
/// The stages cannot be folded into a single set of coefficients (a cubic of a cubic is not a cubic),
/// so they are composed by evaluation: the profile says where to read from, and the manual stage is
/// then asked the same question about *that* radius. Because the whole stack ends up as a table
/// anyway, composing this way costs nothing at render time.
public struct LensCorrectionStack: Equatable, Sendable {
    public var stages: [LensCorrection]

    public init(_ stages: [LensCorrection] = []) {
        self.stages = stages.filter { !$0.isIdentity }
    }

    public var isIdentity: Bool { stages.isEmpty }

    /// The radius each channel reads from and the gain applied, after every stage has had its say.
    public func sample(atRadius r: Float)
        -> (red: Float, green: Float, blue: Float, gain: Float) {
        var red = r, green = r, blue = r, gain: Float = 1
        for stage in stages {
            // Each stage is asked about the radius the stage before it arrived at, which is what
            // makes the composition exact rather than an approximation of two curves added together.
            gain *= stage.vignetting.gain(green)
            let moved = stage.sourceRadii(red: red, green: green, blue: blue)
            red = moved.red
            green = moved.green
            blue = moved.blue
        }
        return (red, green, blue, gain)
    }

    /// Flattens all correction stages into channel-radius ratios and vignette gain for `entries`
    /// radii. Ratios avoid a center-pixel singularity and decouple the renderer from source models.
    public func resamplingTable(entries: Int = 1024, maxRadius: Float = 1)
        -> [Float] {
        precondition(entries >= 2)
        var out = [Float](repeating: 0, count: entries * 4)
        let step = maxRadius / Float(entries - 1)
        for i in 0..<entries {
            // The centre would be nothing divided by nothing. Evaluating a hair off it instead gives
            // the limit the ratio is heading for — the constant term of the curve — to the last bit
            // a Float carries, without the expression needing a special case.
            let r = max(Float(i) * step, step * 1e-3)
            let s = sample(atRadius: r)
            out[i * 4] = s.red / r
            out[i * 4 + 1] = s.green / r
            out[i * 4 + 2] = s.blue / r
            out[i * 4 + 3] = s.gain
        }
        return out
    }

    /// Maximum source-radius ratio across the correction. Values above 1 require source extension
    /// or output cropping. Sampling covers the full radius because some models peak before corners.
    public func sourceReach(maxRadius: Float = 1, samples: Int = 64) -> Float {
        var furthest: Float = 1
        for i in 0...samples {
            let r = max(maxRadius * Float(i) / Float(samples), 1e-6)
            let s = sample(atRadius: r)
            furthest = max(furthest, max(s.red, max(s.green, s.blue)) / r)
        }
        return furthest
    }
}
