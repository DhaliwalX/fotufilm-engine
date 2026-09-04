import Foundation

/// What the file says the picture was taken with. Everything needed to find a profile and to ask it
/// the right question, read off the capture metadata.
public struct LensShot: Equatable, Sendable {
    public var lensModel: String
    public var lensMaker: String?
    public var cameraModel: String?
    /// Focal length in millimetres as marked on the lens, not corrected for sensor size.
    public var focalLength: Float?
    public var aperture: Float?

    public init(lensModel: String, lensMaker: String? = nil,
                cameraModel: String? = nil, focalLength: Float? = nil,
                aperture: Float? = nil) {
        self.lensModel = lensModel
        self.lensMaker = lensMaker
        self.cameraModel = cameraModel
        self.focalLength = focalLength
        self.aperture = aperture
    }
}

/// One measurement of a lens, at one focal length and aperture.
///
/// A zoom is characterised at several focal lengths and read between; vignetting additionally
/// depends on aperture, since stopping down mostly cures it.
public struct LensCalibration: Equatable, Sendable, Codable {
    public var focalLength: Float
    /// Nil on a measurement that does not depend on aperture, which is the usual case for distortion
    /// and lateral chroma.
    public var aperture: Float?
    public var distortion: LensCorrection.Distortion
    public var vignetting: LensCorrection.Vignetting
    public var lateralChroma: LensCorrection.LateralChroma

    public init(focalLength: Float, aperture: Float? = nil,
                distortion: LensCorrection.Distortion = .none,
                vignetting: LensCorrection.Vignetting = .none,
                lateralChroma: LensCorrection.LateralChroma = .none) {
        self.focalLength = focalLength
        self.aperture = aperture
        self.distortion = distortion
        self.vignetting = vignetting
        self.lateralChroma = lateralChroma
    }
}

/// A measured lens: what it is called, what it was measured on, and what it did at each setting.
public struct LensProfile: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var maker: String
    public var model: String
    public var mount: String?
    /// The crop factor of the body the lens was measured on. A profile measured on APS-C describes
    /// only the part of the image circle that body saw, so applying it to the same lens on full
    /// frame would under-correct the corners it never sampled.
    public var cropFactor: Float
    public var calibrations: [LensCalibration]
    /// Where the numbers came from, carried so a picture can say what corrected it.
    public var source: String?

    public init(id: String? = nil, maker: String, model: String,
                mount: String? = nil, cropFactor: Float = 1,
                calibrations: [LensCalibration], source: String? = nil) {
        self.id = id ?? "\(maker)|\(model)|\(cropFactor)"
        self.maker = maker
        self.model = model
        self.mount = mount
        self.cropFactor = cropFactor
        self.calibrations = calibrations.sorted { $0.focalLength < $1.focalLength }
        self.source = source
    }

    public var focalRange: ClosedRange<Float>? {
        guard let first = calibrations.first?.focalLength,
              let last = calibrations.last?.focalLength else { return nil }
        return first...last
    }

    /// The correction this profile predicts at a given setting.
    ///
    /// Focal length is read between the two nearest measurements and held flat outside them, because
    /// a polynomial extrapolated past where it was fitted goes wrong quickly and a lens is not
    /// usually much worse just outside its measured range than just inside it. Aperture is chosen
    /// rather than interpolated for the same reason and because vignetting is the only term that
    /// depends on it.
    public func correction(focalLength: Float?, aperture: Float?)
        -> LensCorrection {
        guard !calibrations.isEmpty else { return .none }
        let focal = focalLength ?? calibrations[calibrations.count / 2].focalLength

        let geometry = bracket(focal, in: calibrations)
        let distortion = interpolatedDistortion(geometry, at: focal)
        let chroma = interpolatedChroma(geometry, at: focal)

        // Vignetting is looked up among the measurements taken at the nearest aperture, so that
        // reading between focal lengths never mixes a wide-open corner with a stopped-down one.
        let vignetteCandidates = nearestAperture(aperture, in: calibrations)
        let vignetteBracket = bracket(focal, in: vignetteCandidates)
        let vignetting = interpolatedVignetting(vignetteBracket, at: focal)

        return LensCorrection(distortion: distortion, vignetting: vignetting,
                              lateralChroma: chroma)
    }

    // MARK: - Reading between measurements

    private func bracket(_ focal: Float, in list: [LensCalibration])
        -> (low: LensCalibration, high: LensCalibration, t: Float)? {
        guard let first = list.first, let last = list.last else { return nil }
        if focal <= first.focalLength { return (first, first, 0) }
        if focal >= last.focalLength { return (last, last, 0) }
        for index in 1..<list.count where list[index].focalLength >= focal {
            let low = list[index - 1], high = list[index]
            let span = high.focalLength - low.focalLength
            let t = span > 0 ? (focal - low.focalLength) / span : 0
            return (low, high, t)
        }
        return (last, last, 0)
    }

    private func nearestAperture(_ aperture: Float?,
                                 in list: [LensCalibration]) -> [LensCalibration] {
        guard let aperture else { return list }
        let apertures = Set(list.compactMap { $0.aperture })
        guard let chosen = apertures.min(by: {
            abs(log2($0) - log2(aperture)) < abs(log2($1) - log2(aperture))
        }) else { return list }
        let matching = list.filter { $0.aperture == chosen }
        return matching.isEmpty ? list : matching
    }

    private func interpolatedDistortion(
        _ bracket: (low: LensCalibration, high: LensCalibration, t: Float)?,
        at focal: Float
    ) -> LensCorrection.Distortion {
        guard let bracket else { return .none }
        guard bracket.t > 0 else { return bracket.low.distortion }
        let t = bracket.t
        switch (bracket.low.distortion, bracket.high.distortion) {
        case (.poly3(let a), .poly3(let b)):
            return .poly3(k1: lerp(a, b, t))
        case (.poly5(let a1, let a2), .poly5(let b1, let b2)):
            return .poly5(k1: lerp(a1, b1, t), k2: lerp(a2, b2, t))
        case (.ptLens(let aa, let ab, let ac), .ptLens(let ba, let bb, let bc)):
            return .ptLens(a: lerp(aa, ba, t), b: lerp(ab, bb, t),
                           c: lerp(ac, bc, t))
        default:
            // Two measurements fitted in different models cannot be averaged coefficient by
            // coefficient; the nearer one is used whole rather than inventing a blend.
            return t < 0.5 ? bracket.low.distortion : bracket.high.distortion
        }
    }

    private func interpolatedVignetting(
        _ bracket: (low: LensCalibration, high: LensCalibration, t: Float)?,
        at focal: Float
    ) -> LensCorrection.Vignetting {
        guard let bracket else { return .none }
        guard bracket.t > 0 else { return bracket.low.vignetting }
        guard case .radial(let a1, let a2, let a3) = bracket.low.vignetting,
              case .radial(let b1, let b2, let b3) = bracket.high.vignetting
        else { return bracket.t < 0.5 ? bracket.low.vignetting
                                      : bracket.high.vignetting }
        let t = bracket.t
        return .radial(k1: lerp(a1, b1, t), k2: lerp(a2, b2, t),
                       k3: lerp(a3, b3, t))
    }

    private func interpolatedChroma(
        _ bracket: (low: LensCalibration, high: LensCalibration, t: Float)?,
        at focal: Float
    ) -> LensCorrection.LateralChroma {
        guard let bracket else { return .none }
        guard bracket.t > 0 else { return bracket.low.lateralChroma }
        let t = bracket.t
        switch (bracket.low.lateralChroma, bracket.high.lateralChroma) {
        case (.linear(let ar, let ab), .linear(let br, let bb)):
            return .linear(red: lerp(ar, br, t), blue: lerp(ab, bb, t))
        case (.poly3(let ar, let ab), .poly3(let br, let bb)):
            return .poly3(
                red: .init(b: lerp(ar.b, br.b, t), c: lerp(ar.c, br.c, t),
                           v: lerp(ar.v, br.v, t)),
                blue: .init(b: lerp(ab.b, bb.b, t), c: lerp(ab.c, bb.c, t),
                            v: lerp(ab.v, bb.v, t)))
        default:
            return t < 0.5 ? bracket.low.lateralChroma
                           : bracket.high.lateralChroma
        }
    }
}

private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

/// Lens profiles and source-name matching.
public struct LensCatalogue: Sendable {
    public private(set) var profiles: [LensProfile]

    public init(profiles: [LensProfile] = []) {
        self.profiles = profiles
    }

    public var isEmpty: Bool { profiles.isEmpty }
    public var count: Int { profiles.count }

    public mutating func add(_ profile: LensProfile) {
        profiles.append(profile)
    }

    /// Normalizes punctuation, spacing, and repeated maker names for profile matching.
    static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "f/", with: "f")
            .replacingOccurrences(of: "ƒ", with: "f")
        let parts = lowered.split { !($0.isLetter || $0.isNumber || $0 == ".") }
        // Words that appear in almost every lens name carry no evidence about which lens it is.
        let noise: Set<String> = ["lens", "camera", "mm", "for", "the"]
        return parts.map(String.init).filter { !noise.contains($0) && !$0.isEmpty }
    }

    /// Name-match score from 0 (no shared terms) to 1 (equivalent terms).
    ///
    /// The score is the share of the *photograph's* words the profile accounts for, penalised for
    /// words the profile adds that the photograph never mentioned. A profile for a different lens in
    /// the same family therefore scores below the right one rather than tying with it.
    static func score(shot: LensShot, profile: LensProfile) -> Float {
        let wanted = tokens(shot.lensModel)
        guard !wanted.isEmpty else { return 0 }
        var offered = Set(tokens(profile.model))
        offered.formUnion(tokens(profile.maker))
        let matched = wanted.filter { offered.contains($0) }.count
        guard matched > 0 else { return 0 }
        let recall = Float(matched) / Float(wanted.count)
        // Words the profile brings that the photograph never mentioned are evidence against it, so a
        // longer name has to account for more of the photograph's words to score the same.
        let extra = Float(max(0, offered.count - matched))
        var total = recall / (1 + extra / Float(wanted.count))
        // The maker agreeing is weak evidence on its own but breaks ties between families.
        if let maker = shot.lensMaker, !maker.isEmpty {
            let makerTokens = Set(tokens(maker))
            if !makerTokens.isDisjoint(with: Set(tokens(profile.maker))) {
                total = min(1, total * 1.1)
            }
        }
        return total
    }

    /// The profile a photograph was most likely taken with, or nil when nothing is close enough to
    /// be worth trusting. Guessing wrong here bends a picture that was straight, so the bar is set
    /// where a partial family match does not clear it.
    public static let matchThreshold: Float = 0.6

    public func match(_ shot: LensShot) -> LensProfile? {
        guard !shot.lensModel.isEmpty else { return nil }
        var best: (profile: LensProfile, score: Float)?
        for profile in profiles {
            let score = Self.score(shot: shot, profile: profile)
            guard score >= Self.matchThreshold else { continue }
            // A zoom that does not reach the focal length recorded on the photograph is the wrong
            // profile however well its name reads.
            if let focal = shot.focalLength, let range = profile.focalRange,
               focal < range.lowerBound * 0.6 || focal > range.upperBound * 1.6 {
                continue
            }
            if best == nil || score > best!.score {
                best = (profile, score)
            }
        }
        return best?.profile
    }

    /// Loads a catalogue from the JSON the app ships and the importer writes.
    public static func load(from data: Data) throws -> LensCatalogue {
        let decoded = try JSONDecoder().decode([LensProfile].self, from: data)
        return LensCatalogue(profiles: decoded)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profiles)
    }
}

/// The four numbers a photographer can reach, on top of whatever a profile found.
///
/// These are deliberately plain: each runs -1…1 and each drives one term of the model. The travel at
/// each end is set to cover what real lenses do and no more — a slider that can bend a picture
/// further than any lens ever bent it is only a way to make a mistake.
public struct LensAdjustment: Equatable, Sendable, Codable {
    /// Barrel at -1, pincushion at +1.
    public var distortion: Double = 0
    /// Corners darker at -1, lifted at +1.
    public var vignetting: Double = 0
    public var redCyan: Double = 0
    public var blueYellow: Double = 0

    public init(distortion: Double = 0, vignetting: Double = 0,
                redCyan: Double = 0, blueYellow: Double = 0) {
        self.distortion = distortion
        self.vignetting = vignetting
        self.redCyan = redCyan
        self.blueYellow = blueYellow
    }

    public static let neutral = LensAdjustment()

    public var isNeutral: Bool {
        distortion == 0 && vignetting == 0 && redCyan == 0 && blueYellow == 0
    }

    /// Full travel bends the corner by a tenth of the half-diagonal, which is about as much
    /// distortion as an uncorrected wide zoom shows.
    static let distortionTravel: Float = 0.1
    /// Full travel puts the corner one and a half stops away from the centre — past what a fast lens
    /// wide open loses, so the correction can always reach it.
    static let vignetteTravel: Float = 1 - 1 / 2.83
    /// Full travel is a half-percent magnification difference between a channel and green. Lateral
    /// chromatic aberration on a real lens is a few tenths of that.
    static let chromaTravel: Float = 0.005

    public var correction: LensCorrection {
        var out = LensCorrection()
        if distortion != 0 {
            out.distortion = .poly3(k1: Float(distortion) * Self.distortionTravel)
        }
        if vignetting != 0 {
            // The sign is read the way the slider is labelled: pushing left says the corners are
            // dark and should come up, which is a transmission below one for the model to undo.
            out.vignetting = .radial(k1: Float(vignetting) * Self.vignetteTravel,
                                     k2: 0, k3: 0)
        }
        if redCyan != 0 || blueYellow != 0 {
            out.lateralChroma = .linear(
                red: 1 + Float(redCyan) * Self.chromaTravel,
                blue: 1 + Float(blueYellow) * Self.chromaTravel)
        }
        return out
    }
}
