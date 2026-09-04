import Foundation

/// Relative spectral sensitivity of a camera's three channels on `SpectralGrid`. The engine uses
/// these measurements to derive the camera-linear to working-space matrix for an illuminant.
public struct CameraSpectralProfile: Equatable, Codable, Sendable {
    /// Key the store and `CameraIdentity.spectralProfileID` refer to this profile by.
    public var id: String
    public var make: String?
    public var model: String?
    /// Three rows — red, green, blue — of `SpectralGrid.count` samples each: the channel's
    /// relative response to unit radiance at each grid wavelength. Only ratios matter; the
    /// matrix derivation normalizes every channel on its own illuminant response.
    public var sensitivity: [[Float]]

    /// Preserves negative lobes in synthetic Luther–Ives profiles. Measured profiles use the
    /// resampling initializer, which clamps negative measurement noise.
    init(id: String, make: String? = nil, model: String? = nil,
         gridSensitivity: [[Float]]) {
        precondition(gridSensitivity.count == 3)
        precondition(gridSensitivity.allSatisfy { $0.count == SpectralGrid.count })
        self.id = id
        self.make = make
        self.model = model
        self.sensitivity = gridSensitivity
    }

    /// Linearly resamples measured sensitivities onto `SpectralGrid`. Values outside the measured
    /// span are zero and negative samples are clamped to zero. `wavelengths` must be strictly
    /// ascending, with one sample per wavelength in each channel.
    public init(id: String, make: String? = nil, model: String? = nil,
                wavelengths: [Float], red: [Float], green: [Float], blue: [Float]) {
        precondition(wavelengths.count >= 2)
        precondition(red.count == wavelengths.count
                     && green.count == wavelengths.count
                     && blue.count == wavelengths.count)
        precondition(zip(wavelengths, wavelengths.dropFirst()).allSatisfy { $0 < $1 })
        self.init(id: id, make: make, model: model, gridSensitivity: [
            Self.resample(wavelengths: wavelengths, values: red),
            Self.resample(wavelengths: wavelengths, values: green),
            Self.resample(wavelengths: wavelengths, values: blue),
        ])
    }

    /// One measured record carried onto the grid: exact at coincident wavelengths, linear
    /// between samples, zero beyond the measured span.
    private static func resample(wavelengths: [Float], values: [Float]) -> [Float] {
        let clamped = values.map { max($0, 0) }
        return SpectralGrid.wavelengths.map { target in
            guard target >= wavelengths[0], target <= wavelengths[wavelengths.count - 1] else {
                return 0
            }
            var high = 0
            while wavelengths[high] < target { high += 1 }
            // A grid point that lands on a measured wavelength returns that sample untouched,
            // so a measurement already on the grid round-trips bit-exactly.
            if wavelengths[high] == target { return clamped[high] }
            let low = high - 1
            let fraction = (target - wavelengths[low])
                / (wavelengths[high] - wavelengths[low])
            return clamped[low] + fraction * (clamped[high] - clamped[low])
        }
    }
}

// MARK: - Colour matrix derivation

extension CameraSpectralProfile {
    /// Derives a 3×3 map from white-balanced camera channels to linear Rec.2020 for `illuminant`.
    /// A least-squares solve maps training reflectances from camera response to CIE colorimetry.
    /// Both sides normalize a perfect reflector to `(1, 1, 1)`, and each solved row is normalized
    /// to preserve neutral white exactly.
    public func matrixToRec2020(illuminant: [Float] = SpectralGrid.d65) -> [SIMD3<Float>] {
        matrixToRec2020(illuminant: illuminant, training: Self.trainingReflectances())
    }

    /// The same solve on a caller-chosen training set. Internal so the accuracy suite can fit
    /// on one half of the reflectances and measure ΔE on the half the solve never saw — a
    /// held-out claim rather than a fit residual.
    func matrixToRec2020(illuminant: [Float],
                           training: [[Float]]) -> [SIMD3<Float>] {
        precondition(illuminant.count == SpectralGrid.count)

        // Normal equations for the shared 3×3 system: one Gram matrix of camera responses,
        // one moment vector per target component. Accumulated in Double because the patches
        // cluster near grey and the Gram matrix is correspondingly ill-conditioned in Float.
        var gram = [Double](repeating: 0, count: 9)
        var moment = [[Double]](repeating: [0, 0, 0], count: 3)
        for reflectance in training {
            let camera = cameraResponse(reflectance: reflectance, illuminant: illuminant)
            let target = Self.colorimetricTarget(reflectance: reflectance,
                                                 illuminant: illuminant)
            let c = [Double(camera.x), Double(camera.y), Double(camera.z)]
            let t = [Double(target.x), Double(target.y), Double(target.z)]
            for i in 0..<3 {
                for j in 0..<3 { gram[i * 3 + j] += c[i] * c[j] }
                for row in 0..<3 { moment[row][i] += c[i] * t[row] }
            }
        }
        // A whisper of ridge keeps a degenerate training set (or a camera with a dead
        // channel) from blowing up the solve; it is far too small to bias a healthy one.
        let ridge = 1e-6 * max((gram[0] + gram[4] + gram[8]) / 3, 1e-12)
        for i in 0..<3 { gram[i * 3 + i] += ridge }

        var rows = [SIMD3<Float>](repeating: .zero, count: 3)
        for row in 0..<3 {
            if let solved = Self.solve3(gram, moment[row]) {
                rows[row] = solved
            } else {
                rows[row] = SIMD3(row == 0 ? 1 : 0, row == 1 ? 1 : 0, row == 2 ? 1 : 0)
            }
        }
        // Exact white preservation: (1, 1, 1) in maps to (1, 1, 1) out. The least-squares rows
        // already sum to nearly one — the training normalization put white on white — so this
        // is a per-mille correction, not a rescue. Off-diagonals may be negative; the *sum* is
        // what a row applies to a neutral, so the sum is what gets pinned.
        return rows.map { row in
            let sum = row.x + row.y + row.z
            guard abs(sum) > 1e-4 else { return row }
            return row / sum
        }
    }

    /// What the sensor reports for a reflectance under an illuminant, white balanced: each
    /// channel's integral of reflectance × illuminant × sensitivity, divided by that channel's
    /// integral against the perfect reflector so that reflectance 1 everywhere reads (1, 1, 1).
    func cameraResponse(reflectance: [Float], illuminant: [Float]) -> SIMD3<Float> {
        var exposure = SIMD3<Float>.zero
        var white = SIMD3<Float>.zero
        for i in 0..<SpectralGrid.count {
            let s = SIMD3(sensitivity[0][i], sensitivity[1][i], sensitivity[2][i])
            exposure += reflectance[i] * illuminant[i] * s
            white += illuminant[i] * s
        }
        func divide(_ value: Float, _ by: Float) -> Float {
            abs(by) > 1e-12 ? value / by : 0
        }
        return SIMD3(divide(exposure.x, white.x), divide(exposure.y, white.y),
                     divide(exposure.z, white.z))
    }

    /// What the reflectance actually looks like: its tristimulus under the illuminant through
    /// the CIE observer, taken to the linear Rec.2020 working space and scaled per channel so
    /// the illuminant's own white sits on (1, 1, 1) — the same normalization `cameraResponse`
    /// applies to the sensor side, which is what makes the two comparable. The solved matrix
    /// therefore lands camera colour directly in the working space.
    static func colorimetricTarget(reflectance: [Float],
                                   illuminant: [Float]) -> SIMD3<Float> {
        var reflected = [Float](repeating: 0, count: SpectralGrid.count)
        for i in 0..<SpectralGrid.count { reflected[i] = reflectance[i] * illuminant[i] }
        var stimulus = SpectralGrid.xyz(spectrum: reflected)
        var white = SpectralGrid.xyz(spectrum: illuminant)
        let luminance = max(white.y, 1e-12)
        stimulus /= luminance
        white /= luminance
        let rgb = SpectralGrid.linearRec2020(fromXYZ: stimulus)
        let whiteRGB = SpectralGrid.linearRec2020(fromXYZ: white)
        func divide(_ value: Float, _ by: Float) -> Float {
            abs(by) > 1e-12 ? value / by : 0
        }
        return SIMD3(divide(rgb.x, whiteRGB.x), divide(rgb.y, whiteRGB.y),
                     divide(rgb.z, whiteRGB.z))
    }

    /// The reflectances the matrix is trained on. When the measured-reflectance table is loaded
    /// these are bounded posterior reconstructions of `trainingPatchesDisplayP3` whose colours
    /// span the gamut the camera will actually meet. Headless, without the
    /// bundled table, the reconstruction degenerates to flat spectra (every patch a grey),
    /// which cannot constrain a colour matrix; a probe patch detects that and an analytic set
    /// of Gaussian-bump reflectances stands in so the derivation still works everywhere.
    static func trainingReflectances() -> [[Float]] {
        let probe = SpectralRuntime.reconstructedReflectance(
            linearRGB: SIMD3(0.9, 0.1, 0.1))
        let spread = (probe.max() ?? 0) - (probe.min() ?? 0)
        guard spread > 1e-3 else { return analyticTrainingReflectances() }
        // The reconstruction reads the scene working space, so the P3 patches step through
        // the ingest matrix first. P3 sits inside the 2020 cube but for a −0.0012 sliver at
        // the red primary, which the recovery's physical-light clamp absorbs.
        return trainingPatchesDisplayP3.map {
            SpectralRuntime.reconstructedReflectance(
                linearRGB: ColorScience.linearDisplayP3ToRec2020($0))
        }
    }

    /// Training colours in linear Display P3: the 24 classic reflectance-like patches (nominal
    /// chart values — anchors for the solve, not a claim of measurement) plus a deterministic
    /// sweep of hue, chroma and lightness that fills in the directions a chart leaves sparse.
    static let trainingPatchesDisplayP3: [SIMD3<Float>] = {
        // The classic chart, as 8-bit sRGB nominals, linearized and taken to P3 below.
        let classicSRGB: [SIMD3<Float>] = [
            SIMD3(115, 82, 68), SIMD3(194, 150, 130), SIMD3(98, 122, 157),
            SIMD3(87, 108, 67), SIMD3(133, 128, 177), SIMD3(103, 189, 170),
            SIMD3(214, 126, 44), SIMD3(80, 91, 166), SIMD3(193, 90, 99),
            SIMD3(94, 60, 108), SIMD3(157, 188, 64), SIMD3(224, 163, 46),
            SIMD3(56, 61, 150), SIMD3(70, 148, 73), SIMD3(175, 54, 60),
            SIMD3(231, 199, 31), SIMD3(187, 86, 149), SIMD3(8, 133, 161),
            SIMD3(243, 243, 242), SIMD3(200, 200, 200), SIMD3(160, 160, 160),
            SIMD3(122, 122, 122), SIMD3(85, 85, 85), SIMD3(52, 52, 52),
        ]
        var patches = classicSRGB.map { encoded -> SIMD3<Float> in
            let linear = SIMD3(ColorScience.srgbToLinear(encoded.x / 255),
                               ColorScience.srgbToLinear(encoded.y / 255),
                               ColorScience.srgbToLinear(encoded.z / 255))
            return ColorScience.linearSRGBToDisplayP3(linear)
        }
        // 10 hues × 2 chroma levels × 3 lightnesses: a cosine colour wheel in linear sRGB,
        // chroma bounded by the lightness headroom so every patch stays in range.
        for hueStep in 0..<10 {
            let angle = Float(hueStep) / 10 * 2 * .pi
            for chroma in [Float(0.35), 0.8] {
                for lightness in [Float(0.2), 0.45, 0.7] {
                    let reach = chroma * min(lightness, 1 - lightness)
                    let linear = SIMD3(
                        lightness + reach * cos(angle),
                        lightness + reach * cos(angle - 2 * .pi / 3),
                        lightness + reach * cos(angle + 2 * .pi / 3))
                    patches.append(ColorScience.linearSRGBToDisplayP3(linear))
                }
            }
        }
        return patches
    }()

    /// Smooth Gaussian-bump reflectances across the grid, plus flat greys: enough spectral
    /// variety to condition the solve when no reconstruction model is on disk.
    static func analyticTrainingReflectances() -> [[Float]] {
        var spectra: [[Float]] = []
        for center in stride(from: Float(410), through: 770, by: 40) {
            for width in [Float(25), 60] {
                for amplitude in [Float(0.3), 0.85] {
                    spectra.append(SpectralGrid.wavelengths.map { wavelength in
                        let x = (wavelength - center) / width
                        return 0.04 + amplitude * exp(-0.5 * x * x)
                    })
                }
            }
        }
        for level in [Float(0.05), 0.18, 0.5, 0.95] {
            spectra.append([Float](repeating: level, count: SpectralGrid.count))
        }
        return spectra
    }

    /// Gaussian elimination with partial pivoting on the 3×3 normal equations.
    private static func solve3(_ matrix: [Double], _ rhs: [Double]) -> SIMD3<Float>? {
        var a = matrix, b = rhs
        for column in 0..<3 {
            var pivot = column
            for row in (column + 1)..<3
            where abs(a[row * 3 + column]) > abs(a[pivot * 3 + column]) {
                pivot = row
            }
            guard abs(a[pivot * 3 + column]) > 1e-12 else { return nil }
            if pivot != column {
                for k in 0..<3 { a.swapAt(column * 3 + k, pivot * 3 + k) }
                b.swapAt(column, pivot)
            }
            for row in (column + 1)..<3 {
                let factor = a[row * 3 + column] / a[column * 3 + column]
                guard factor != 0 else { continue }
                for k in column..<3 { a[row * 3 + k] -= factor * a[column * 3 + k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: 3)
        for row in stride(from: 2, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<3 { sum -= a[row * 3 + k] * x[k] }
            x[row] = sum / a[row * 3 + row]
        }
        return SIMD3<Float>(Float(x[0]), Float(x[1]), Float(x[2]))
    }
}

// MARK: - Dual-illuminant matrices

/// The two anchor solves a camera needs to be rendered under any scene white, held together so
/// call sites pay for the least-squares derivation once and blend forever after.
///
/// Solving a fresh matrix per correlated colour temperature would be pointless work: a camera's
/// correction varies smoothly along the locus, and in mired — the reciprocal scale colour
/// temperature is perceptually and physically linear in — it is close to linear between a warm
/// and a cool anchor. Two solves that bracket the locus therefore pin the whole family, which
/// is exactly the bet DNG's dual-illuminant calibration makes: `ColorMatrix1`/`ColorMatrix2`
/// under illuminant A and D65, interpolated by inverse CCT. The anchors here are the same pair
/// — CIE A at 2856 K and the CIE daylight of D65's temperature, 6504 K.
public struct DualIlluminantMatrices: Equatable, Sendable {
    /// The CCT of the warm anchor: CIE standard illuminant A.
    public static let tungstenKelvin: Float = 2856
    /// The CCT of the cool anchor: the CIE daylight series at D65's temperature.
    public static let daylightKelvin: Float = 6504

    /// Rows of the matrix solved under `Illuminant.a`.
    public let tungsten: [SIMD3<Float>]
    /// Rows of the matrix solved under `Illuminant.daylight(kelvin: 6504)`.
    public let daylight: [SIMD3<Float>]

    public init(tungsten: [SIMD3<Float>], daylight: [SIMD3<Float>]) {
        precondition(tungsten.count == 3 && daylight.count == 3)
        self.tungsten = tungsten
        self.daylight = daylight
    }

    /// The matrix for a scene at `cct`, by the DNG dual-illuminant rule: the anchors blended
    /// linearly in mired, weight (1/cct − 1/6504) / (1/2856 − 1/6504) on the tungsten side,
    /// clamped to [0, 1] so temperatures beyond an anchor hold that anchor rather than
    /// extrapolate a correction no solve ever produced.
    ///
    /// At the anchor temperatures the anchor matrices come back untouched. Between them the
    /// blend is re-pinned to exact white preservation: each anchor already maps (1, 1, 1) to
    /// (1, 1, 1) by its own row normalization, but only to within a few ulps, and a linear mix
    /// of two almost-exact rows can drift — so the blended rows get the same division by their
    /// sum the solver applies, and a camera grey stays grey at every temperature.
    public func matrix(cct: Float) -> [SIMD3<Float>] {
        let coolMired = 1 / Self.daylightKelvin
        let warmMired = 1 / Self.tungstenKelvin
        let mired = 1 / max(cct, 1)
        let weight = clamp((mired - coolMired) / (warmMired - coolMired), 0, 1)
        if weight == 1 { return tungsten }
        if weight == 0 { return daylight }
        return zip(tungsten, daylight).map { warm, cool in
            let row = weight * warm + (1 - weight) * cool
            let sum = row.x + row.y + row.z
            guard abs(sum) > 1e-4 else { return row }
            return row / sum
        }
    }

    /// Returns the illuminant-dependent delta for already-colorimetric decoded pixels:
    ///
    ///     correction(cct) = M(cct) · M(6504)⁻¹
    ///
    /// The product uses Double precision and each row is normalized to preserve white. It is
    /// identity at the 6504 K daylight anchor.
    public func correction(cct: Float) -> [SIMD3<Float>] {
        let identity: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        guard let inverse = Self.invert3(daylight) else { return identity }
        let blended = matrix(cct: cct)
        var rows = [SIMD3<Float>](repeating: .zero, count: 3)
        for row in 0..<3 {
            var out = SIMD3<Double>.zero
            for k in 0..<3 {
                let weight = Double(blended[row][k])
                out.x += weight * inverse[k].x
                out.y += weight * inverse[k].y
                out.z += weight * inverse[k].z
            }
            let sum = out.x + out.y + out.z
            if abs(sum) > 1e-4 { out /= sum }
            rows[row] = SIMD3(Float(out.x), Float(out.y), Float(out.z))
        }
        return rows
    }

    /// The largest elementwise distance of `rows` from the identity — how much a correction
    /// would actually move the pixels, which is what decides whether it is worth a pass.
    public static func maxDeviationFromIdentity(_ rows: [SIMD3<Float>]) -> Float {
        var deviation: Float = 0
        for row in 0..<3 {
            for column in 0..<3 {
                let expected: Float = row == column ? 1 : 0
                deviation = max(deviation, abs(rows[row][column] - expected))
            }
        }
        return deviation
    }

    /// Gauss–Jordan inverse of a 3×3 in Double, or nil when the matrix is singular. Double
    /// because the result multiplies against another anchor and the product's distance from
    /// identity is asserted at 1e-6.
    static func invert3(_ rows: [SIMD3<Float>]) -> [SIMD3<Double>]? {
        var a = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var inv = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for r in 0..<3 {
            a[r] = [Double(rows[r].x), Double(rows[r].y), Double(rows[r].z)]
            inv[r][r] = 1
        }
        for column in 0..<3 {
            var pivot = column
            for row in (column + 1)..<3 where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-12 else { return nil }
            if pivot != column {
                a.swapAt(column, pivot)
                inv.swapAt(column, pivot)
            }
            let lead = a[column][column]
            for k in 0..<3 {
                a[column][k] /= lead
                inv[column][k] /= lead
            }
            for row in 0..<3 where row != column {
                let factor = a[row][column]
                guard factor != 0 else { continue }
                for k in 0..<3 {
                    a[row][k] -= factor * a[column][k]
                    inv[row][k] -= factor * inv[column][k]
                }
            }
        }
        return inv.map { SIMD3($0[0], $0[1], $0[2]) }
    }
}

extension CameraSpectralProfile {
    /// Solves the two anchor matrices for this camera. The solves are the expensive half of
    /// the dual-illuminant scheme — two least-squares derivations over the training set — so
    /// call sites that render at varying temperatures should build this once and keep it;
    /// blending afterwards is nine multiply-adds.
    public func dualIlluminantMatrices() -> DualIlluminantMatrices {
        DualIlluminantMatrices(
            tungsten: matrixToRec2020(illuminant: Illuminant.a),
            daylight: matrixToRec2020(
                illuminant: Illuminant.daylight(kelvin: DualIlluminantMatrices.daylightKelvin)))
    }

    /// The camera-to-working-space matrix for a scene at `cct`, as a one-shot convenience: both
    /// anchors are solved on every call. Anything called per frame or per slider tick should
    /// hold a `DualIlluminantMatrices` instead.
    public func matrix(cct: Float) -> [SIMD3<Float>] {
        dualIlluminantMatrices().matrix(cct: cct)
    }
}

// MARK: - Store

/// The registry `LightDomain.cameraLinear` and `CameraIdentity` resolve through. The Academy's
/// measured rawtoaces dataset (`CameraProfiles`) loads lazily on first lookup;
/// callers with their own measurements `register` on top, and an explicit registration always
/// beats a bundled one. Nothing here is fabricated — every bundled curve is a measurement.
public enum CameraSpectralProfileStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var profiles: [String: CameraSpectralProfile] = [:]
    /// Case-folded "make\u{1F}model" to profile id, for files that name the camera without
    /// naming a profile.
    nonisolated(unsafe) private static var identities: [String: String] = [:]

    public static func register(_ profile: CameraSpectralProfile) {
        lock.lock()
        defer { lock.unlock() }
        profiles[profile.id] = profile
        if let key = identityKey(make: profile.make, model: profile.model) {
            identities[key] = profile.id
        }
    }

    /// Registers bundled data without replacing an existing profile. Explicit `register` calls
    /// therefore take precedence over bundled profiles.
    static func registerIfAbsent(_ profile: CameraSpectralProfile) {
        lock.lock()
        defer { lock.unlock() }
        if profiles[profile.id] == nil {
            profiles[profile.id] = profile
        }
        if let key = identityKey(make: profile.make, model: profile.model),
           identities[key] == nil {
            identities[key] = profile.id
        }
    }

    public static func profile(id: String) -> CameraSpectralProfile? {
        loadBundledProfiles()
        lock.lock()
        defer { lock.unlock() }
        return profiles[id]
    }

    /// Resolves an explicit profile ID first, then a case-insensitive make/model match. Returns nil
    /// for an unknown camera.
    public static func resolve(_ camera: CameraIdentity?) -> CameraSpectralProfile? {
        guard let camera else { return nil }
        loadBundledProfiles()
        lock.lock()
        defer { lock.unlock() }
        if let id = camera.spectralProfileID, let found = profiles[id] {
            return found
        }
        if let key = identityKey(make: camera.make, model: camera.model),
           let id = identities[key] {
            return profiles[id]
        }
        return nil
    }

    /// Normalizes vendor make/model strings for symmetric registration and lookup. It keeps the
    /// first make token and removes a repeated make prefix from the model.
    private static func identityKey(make: String?, model: String?) -> String? {
        guard let make, let model else { return nil }
        let fold = { (s: String) in
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard let brand = fold(make).split(whereSeparator: \.isWhitespace).first
        else { return nil }
        var parts = fold(model).split(whereSeparator: \.isWhitespace)
        if parts.count > 1, parts[0] == brand { parts.removeFirst() }
        guard !parts.isEmpty else { return nil }
        return brand + "\u{1F}" + parts.joined(separator: " ")
    }
}
