import Foundation

/// What a negative was scanned with and under, which sets what each of the scan's three channels
/// sees of the film: the lamp's spectrum through the camera's channels, as its file is decoded.
public struct NegativeScanSetup: Equatable, Sendable {
    /// What took the scan.
    public enum Camera: Equatable, Sendable {
        /// A camera whose file reads colour as the eye does: the Rec. 2020 primaries'
        /// colour-matching functions.
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
        guard case .profile(let id) = camera,
              let profile = CameraSpectralProfileStore.profile(id: id) else {
            return (0..<3).map { channel in
                (0..<SpectralGrid.count).map { i in
                    SpectralGrid.linearRec2020(fromXYZ: SIMD3(
                        SpectralGrid.xBar[i], SpectralGrid.yBar[i], SpectralGrid.zBar[i]))[channel]
                }
            }
        }
        // The file's decoder balances each sensor channel on its white, then mixes the three into
        // Rec. 2020 with the camera's matrix for that white.
        let cct = kelvin.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? light.kelvin
        let locus = Illuminant.atLocus(kelvin: cct)
        let white = self.white.flatMap { Illuminant.matched($0, base: locus) } ?? locus
        let matrix = decoderMatrix ?? CameraProfileCorrection.matrices(for: profile).matrix(cct: cct)
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
