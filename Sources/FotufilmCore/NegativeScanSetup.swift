import Foundation

/// What a negative was scanned with and under, which sets what each of the scan's three channels
/// sees of the film: the lamp's spectrum through the camera's channels, as its file is decoded.
public struct NegativeScanSetup: Equatable, Sendable {
    /// What took the scan.
    public enum Camera: Equatable, Sendable {
        /// A camera without a measured profile of its own: modelled with the median spectral
        /// sensitivity of the bundled Bayer CMOS cameras (`genericCMOSProfile`), white-balanced
        /// on the lamp and mapped to Rec. 2020.
        case generic
        /// A film scanner: three narrow bands under its own lamp, whatever `light` says.
        case scanner
        /// A camera with measured channels (`CameraSpectralProfileStore`), by its profile's ID.
        /// One the store does not hold reads as `generic`.
        case profile(String)

        /// The name an edit keeps: `generic`, `scanner`, or a profile's ID.
        public var name: String {
            switch self {
            case .generic: return "generic"
            case .scanner: return "scanner"
            case .profile(let id): return id
            }
        }

        public init(name: String) {
            switch name {
            case "generic": self = .generic
            case "scanner": self = .scanner
            default: self = .profile(name)
            }
        }
    }

    public var light: NegativeScanCrosstalk.Light
    public var camera: Camera
    /// The white balance the camera's file was decoded on, in kelvin, which sets how its channels
    /// were mixed into the scan's. Nil takes it as balanced on the lamp.
    public var kelvin: Float?
    /// The chromaticity (CIE xy) of that white where the decoder says it, which a camera's own
    /// balance on a negative can leave well off the lamps' colours. Nil is the white of `kelvin`.
    public var white: SIMD2<Float>?
    /// The matrix the file's decoder mixed a measured camera's balanced channels into the scan's
    /// with: rows the scan's red, green and blue over the sensor's. Decoders each bring their own,
    /// and a dense negative's blue is a small difference of the sensor's green and blue that
    /// follows it closely. Nil takes the camera's own for `kelvin` (`DualIlluminantMatrices`).
    public var matrix: [SIMD3<Float>]?

    public init(light: NegativeScanCrosstalk.Light = .white, camera: Camera = .generic,
                kelvin: Float? = nil, white: SIMD2<Float>? = nil, matrix: [SIMD3<Float>]? = nil) {
        self.light = light
        self.camera = camera
        self.kelvin = kelvin
        self.white = white
        self.matrix = matrix
    }

    /// Whether the model knows the setup well enough to say how much density a scan's channel
    /// reads of a dye: a measured camera, a film scanner's bands, or LEDs that light one channel
    /// each. A camera nobody measured under a lamp of unknown spectrum is modelled with the median
    /// bundled Bayer CMOS sensor (`genericCMOSProfile`), which predicts dye cross-talk far closer
    /// than colorimetric eye curves yet still leaves overall red/blue scale uncertain: a white
    /// lamp's red end alone moves that by a third. A reading then keeps the scan's own density of
    /// green as the film's (`weights(_:knownScale:)`).
    public var knowsScale: Bool {
        if light == .rgb || camera == .scanner { return true }
        if case .profile(let id) = camera { return CameraSpectralProfileStore.profile(id: id) != nil }
        return false
    }

    /// A fit's weights as a reading through this setup takes them: as fitted where the setup's
    /// scale is known, else scaled so a grey's green record reads the density the scan's green
    /// channel does, `green` being what the fit's green record reads of its own channel alone
    /// along the greys.
    public func weights(_ fitted: [SIMD3<Float>], green: Float) -> [SIMD3<Float>] {
        guard !knowsScale, green.isFinite, green > 0 else { return fitted }
        return fitted.map { $0 / green }
    }

    /// What each channel of the scan sees per `SpectralGrid` wavelength: three rows, red, green
    /// and blue, each summing to one. A camera's channels can be negative where its file's colour
    /// matrix subtracts one sensor channel from another.
    public func response() -> [[Float]] {
        let rows: [[Float]]
        if light == .rgb {
            rows = Self.bands(NegativeScanCrosstalk.Light.rgbBands)
        } else if camera == .scanner {
            rows = Self.bands(Self.scannerBands)
        } else {
            let lamp = light.spectrum
            let channels = cameraChannels(lamp: lamp)
            rows = channels.map { channel in (0..<SpectralGrid.count).map { channel[$0] * lamp[$0] } }
        }
        return rows.map { row in
            let total = row.reduce(0, +)
            return total > 0 ? row.map { $0 / total } : row
        }
    }

    /// The camera's channels as its decoded file carries them, before the lamp.
    private func cameraChannels(lamp: [Float]) -> [[Float]] {
        let measured: CameraSpectralProfile?
        if case .profile(let id) = camera {
            measured = CameraSpectralProfileStore.profile(id: id)
        } else {
            measured = nil
        }
        let profile = measured ?? Self.genericCMOSProfile
        // A measured camera's file carries its decoder's white and matrix; a generic camera is
        // balanced on the lamp's locus and mapped with the median CMOS sensor's own matrix.
        let cct = (measured != nil ? kelvin.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } : nil)
            ?? light.kelvin
        let locus = Illuminant.atLocus(kelvin: cct)
        let white = (measured != nil ? self.white.flatMap { Illuminant.matched($0, base: locus) } : nil)
            ?? locus
        let matrix = (measured != nil ? decoderMatrix : nil)
            ?? CameraProfileCorrection.matrices(for: profile).matrix(cct: cct)
        let balanced: [[Float]] = profile.sensitivity.map { sensor in
            let level = zip(sensor, white).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            return level > 0 ? sensor.map { $0 / level } : sensor
        }
        return (0..<3).map { channel in
            (0..<SpectralGrid.count).map { i in
                matrix[channel].x * balanced[0][i] + matrix[channel].y * balanced[1][i]
                    + matrix[channel].z * balanced[2][i]
            }
        }
    }

    /// Wavelength-wise median relative spectral sensitivity across the bundled Academy `rawtoaces`
    /// Bayer CMOS camera profiles on `SpectralGrid` (380–780 nm, 5 nm steps), embedded directly so
    /// hosts without the bundled profile directory (such as WASM) share the exact prior.
    static let genericCMOSProfile = CameraSpectralProfile(id: "_generic-cmos", gridSensitivity: [
        [
            0.00033, 0.00065, 0.00098, 0.00174, 0.00317, 0.00444, 0.00792, 0.01732, 0.02892,
            0.04461, 0.05835, 0.05054, 0.04709, 0.03905, 0.03561, 0.03553, 0.03391, 0.03851,
            0.04120, 0.04437, 0.05279, 0.06105, 0.06103, 0.06528, 0.07345, 0.08448, 0.09740,
            0.11980, 0.14198, 0.15434, 0.16584, 0.16581, 0.13824, 0.11018, 0.08812, 0.08208,
            0.07866, 0.10487, 0.20348, 0.42992, 0.67028, 0.85180, 1.00000, 0.99002, 0.97346,
            0.92904, 0.87627, 0.78356, 0.69861, 0.62108, 0.54858, 0.49330, 0.44966, 0.39700,
            0.34353, 0.29612, 0.25398, 0.21761, 0.17399, 0.12337, 0.07730, 0.04837, 0.02085,
            0.01276, 0.00442, 0.00373, 0.00304, 0.00236, 0.00177, 0.00101, 0.00032, 0.00032,
            0.00032, 0.00032, 0.00031, 0.00031, 0.00030, 0.00030, 0.00030, 0.00030, 0.00030,
        ],
        [
            0.00029, 0.00058, 0.00086, 0.00142, 0.00269, 0.00374, 0.01097, 0.02715, 0.05677,
            0.07127, 0.08112, 0.09905, 0.11763, 0.12753, 0.14227, 0.16206, 0.18837, 0.28247,
            0.38602, 0.45590, 0.49904, 0.51920, 0.55409, 0.61465, 0.71036, 0.80385, 0.90351,
            0.93294, 0.97674, 0.98916, 1.00000, 0.99674, 0.97769, 0.94632, 0.92351, 0.86853,
            0.81175, 0.74998, 0.68559, 0.61526, 0.54488, 0.46610, 0.39258, 0.32326, 0.25347,
            0.19763, 0.14069, 0.10482, 0.07290, 0.05811, 0.04642, 0.03928, 0.03396, 0.02903,
            0.02422, 0.02147, 0.01840, 0.01647, 0.01560, 0.01306, 0.00969, 0.00664, 0.00372,
            0.00261, 0.00114, 0.00100, 0.00084, 0.00067, 0.00053, 0.00037, 0.00021, 0.00021,
            0.00021, 0.00021, 0.00020, 0.00020, 0.00020, 0.00020, 0.00020, 0.00020, 0.00020,
        ],
        [
            0.00077, 0.00141, 0.00211, 0.00497, 0.01433, 0.02270, 0.10072, 0.26711, 0.51079,
            0.64499, 0.77923, 0.83929, 0.90817, 0.93530, 0.96497, 0.98113, 1.00000, 0.98808,
            0.98324, 0.95403, 0.92622, 0.84904, 0.77508, 0.69118, 0.59996, 0.50941, 0.42198,
            0.34512, 0.26885, 0.22148, 0.17469, 0.14466, 0.12407, 0.10006, 0.07507, 0.05930,
            0.04360, 0.03305, 0.02509, 0.02141, 0.01809, 0.01607, 0.01425, 0.01262, 0.01083,
            0.00989, 0.00894, 0.00856, 0.00805, 0.00846, 0.00892, 0.00910, 0.00897, 0.00976,
            0.01040, 0.01027, 0.00985, 0.00911, 0.00836, 0.00663, 0.00378, 0.00266, 0.00138,
            0.00090, 0.00046, 0.00041, 0.00035, 0.00028, 0.00022, 0.00015, 0.00008, 0.00008,
            0.00008, 0.00008, 0.00008, 0.00008, 0.00008, 0.00008, 0.00008, 0.00008, 0.00008,
        ],
    ])

    /// `matrix` where it is one a decoder could have used: three finite rows.
    private var decoderMatrix: [SIMD3<Float>]? {
        guard let matrix, matrix.count == 3,
              matrix.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        return matrix
    }

    /// A film scanner's channels: narrow bands near a densitometer's, peaks and full widths at
    /// half maximum in nm. Scanners differ; this stands for one that reads each dye near its peak.
    static let scannerBands: [(peak: Float, width: Float)] = [(645, 30), (535, 30), (450, 25)]

    static func bands(_ bands: [(peak: Float, width: Float)]) -> [[Float]] {
        bands.map { band in
            let sigma = band.width / 2.3548
            return SpectralGrid.wavelengths.map { exp(-0.5 * pow(($0 - band.peak) / sigma, 2)) }
        }
    }
}

extension NegativeScanCrosstalk.Light {
    /// Red, green and blue LEDs (a SmallRig RM120's, measured on a scanning camera): Gaussian
    /// bands at their peaks and full widths at half maximum, in nm.
    static let rgbBands: [(peak: Float, width: Float)] = [(625, 18), (522, 30), (455, 22)]

    /// The lamp's spectrum on `SpectralGrid`, at any scale. The three LEDs of `rgb` light one
    /// channel each, so together they stand here only for the white they add up to.
    public var spectrum: [Float] {
        switch self {
        case .white: return Self.whiteLED
        case .screen: return Self.screenWhite
        case .halogen: return Illuminant.planckian(kelvin: kelvin)
        case .rgb: return Self.mixed(Self.rgbBands)
        }
    }

    /// The lamp's nominal colour temperature, which a camera balanced on it decodes at.
    public var kelvin: Float {
        switch self {
        case .white: return 5500
        case .halogen: return 3200
        case .screen, .rgb: return 6500
        }
    }

    /// A high-CRI white LED panel near 5500 K: a blue pump LED at 452 nm under a broad phosphor.
    static let whiteLED: [Float] = {
        let pump = NegativeScanSetup.bands([(452, 22)])[0]
        let phosphor = SpectralGrid.asymmetricGaussian(peak: 550, leftSigma: 45, rightSigma: 85)
        return (0..<SpectralGrid.count).map { 1.7 * pump[$0] + phosphor[$0] }
    }()

    /// A phone's or tablet's OLED screen showing white: three narrow emitters, in the proportion
    /// that adds up to D65.
    static let screenWhite: [Float] = mixed([(626, 36), (528, 30), (460, 20)])

    /// Three bands in the proportion that adds up to D65 white.
    private static func mixed(_ bands: [(peak: Float, width: Float)]) -> [Float] {
        let emitters = NegativeScanSetup.bands(bands)
        let primaries = emitters.map { SpectralGrid.xyz(spectrum: $0) }
        let white = SpectralGrid.xyz(spectrum: SpectralGrid.d65)
        // Cramer's rule for the three emitters' levels.
        func determinant(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
            a.x * (b.y * c.z - b.z * c.y) - b.x * (a.y * c.z - a.z * c.y)
                + c.x * (a.y * b.z - a.z * b.y)
        }
        let whole = determinant(primaries[0], primaries[1], primaries[2])
        let levels = [determinant(white, primaries[1], primaries[2]),
                      determinant(primaries[0], white, primaries[2]),
                      determinant(primaries[0], primaries[1], white)].map { $0 / whole }
        return (0..<SpectralGrid.count).map { i in
            levels[0] * emitters[0][i] + levels[1] * emitters[1][i] + levels[2] * emitters[2][i]
        }
    }
}
