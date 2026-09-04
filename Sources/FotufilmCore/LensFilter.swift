import Foundation

/// Spectral absorption and surface reflection for a filter in front of the lens.
/// Absorption changes layer exposure; air-glass reflections contribute transmission loss and
/// veiling glare. Polarizing, spatial-diffusion, and graduated filters are outside this model.

// MARK: - Optical materials

/// Two-term Cauchy refractive-index model `n(λ) = A + B / λ²`, with λ in micrometres.
/// Across 380–780 nm, the omitted third term changes glass index by less than 2×10⁻⁴.
public struct OpticalMaterial: Equatable, Sendable, Codable {
    public var a: Float
    public var b: Float

    public init(a: Float, b: Float = 0) {
        self.a = a
        self.b = b
    }

    public func index(wavelengthNM: Float) -> Float {
        let micron = wavelengthNM / 1000
        return a + b / (micron * micron)
    }

    /// The wavelength coatings are designed on and where their layer thicknesses are quoted:
    /// the middle of the photopic band, where the eye and the film's green record both peak.
    public static let designWavelengthNM: Float = 550

    /// Borosilicate crown, the glass a screw-in filter is ground from. n(550) ≈ 1.5185.
    public static let crownGlass = OpticalMaterial(a: 1.5046, b: 0.00420)
    /// Dyed gelatin on a lacquered support — the Wratten construction. Slightly denser than
    /// crown, which is why an uncoated gelatin filter loses marginally more light than an
    /// uncoated glass one.
    public static let gelatin = OpticalMaterial(a: 1.5150, b: 0.00420)
    /// Cast optical resin (CR-39), what a modern dyed square filter is usually made of.
    public static let opticalResin = OpticalMaterial(a: 1.4830, b: 0.00450)

    /// Magnesium fluoride, the single-layer anti-reflection coating.
    public static let magnesiumFluoride = OpticalMaterial(a: 1.3684, b: 0.00280)
    /// Aluminium oxide, the medium-index layer of a broadband stack.
    public static let aluminiumOxide = OpticalMaterial(a: 1.6455, b: 0.00280)
    /// Zirconium dioxide, the high-index layer.
    public static let zirconiumDioxide = OpticalMaterial(a: 2.0855, b: 0.00450)
}

/// Thin-film coating layer with optical thickness measured in design-wavelength units.
public struct CoatingLayer: Equatable, Sendable, Codable {
    public var material: OpticalMaterial
    public var opticalThicknessWaves: Float

    public init(material: OpticalMaterial, opticalThicknessWaves: Float) {
        self.material = material
        self.opticalThicknessWaves = opticalThicknessWaves
    }

    /// Physical thickness in nanometres, fixed at manufacture from the design wavelength. The
    /// phase the layer imposes then moves with wavelength through both `d` and `n(λ)`.
    var thicknessNM: Float {
        opticalThicknessWaves * OpticalMaterial.designWavelengthNM
            / material.index(wavelengthNM: OpticalMaterial.designWavelengthNM)
    }
}

/// Filter-face coating used to compute normal-incidence reflectance with a characteristic matrix.
public enum FilterCoating: String, Equatable, Sendable, Codable, CaseIterable {
    /// Bare polished glass. Fresnel alone: 4.3% per face, 8.2% of the light gone before the dye
    /// has absorbed anything, and the largest ghost a filter can hand the lens.
    case uncoated
    /// One quarter-wave of magnesium fluoride. The classic single coating: a minimum at the
    /// design wavelength and a rise at both ends of the band, which is the purple bloom you see
    /// looking into the glass at an angle.
    case singleLayer
    /// The textbook three-layer broadband stack, quarter–half–quarter from the glass outward:
    /// aluminium oxide, zirconium dioxide, magnesium fluoride. The half-wave layer is an
    /// absentee at 550 nm and flattens the reflectance either side of it.
    case multiCoated

    /// The stack, ordered from the incident medium inward, which is the order the characteristic
    /// matrices multiply in.
    var layers: [CoatingLayer] {
        switch self {
        case .uncoated:
            return []
        case .singleLayer:
            return [CoatingLayer(material: .magnesiumFluoride, opticalThicknessWaves: 0.25)]
        case .multiCoated:
            // Not the textbook quarter–half–quarter. That stack is only designed at 550 nm, and
            // away from its design point the half-wave layer stops being an absentee and starts
            // being a high-index reflector: at 380 nm it returns 9% of the light, twice what
            // bare glass does. A real broadband coating is a solved design, so this one is
            // solved too — the three thicknesses were swept against the reflectance of the whole
            // visible band, and these are the set that holds it flattest. It sits under 0.2%
            // from 420 to 640 nm and under 1% to 700, and rises to about 3% at the ends of the
            // grid, which is what a good multicoating measures.
            return [
                CoatingLayer(material: .magnesiumFluoride, opticalThicknessWaves: 0.23),
                CoatingLayer(material: .zirconiumDioxide, opticalThicknessWaves: 0.46),
                CoatingLayer(material: .aluminiumOxide, opticalThicknessWaves: 0.23),
            ]
        }
    }

    public var label: String {
        switch self {
        case .uncoated: return "Uncoated"
        case .singleLayer: return "Single-coated"
        case .multiCoated: return "Multi-coated"
        }
    }
}

/// Reflectance of a coated surface at normal incidence, by the characteristic-matrix method.
///
/// Each layer contributes `[[cos δ, i·sin δ / n], [i·n·sin δ, cos δ]]` with `δ = 2π n d / λ`; the
/// product acting on the substrate's admittance gives the stack's, and Fresnel's coefficient
/// between that and the incident medium gives the amplitude. With no layers this reduces exactly
/// to `((n − 1) / (n + 1))²`, so an uncoated surface is not a separate code path.
enum ThinFilm {
    /// Complex arithmetic in two floats. Small enough that pulling in a numerics package to
    /// multiply four 2×2 matrices would cost more than it saves.
    struct Complex {
        var re: Float
        var im: Float

        static func * (a: Complex, b: Complex) -> Complex {
            Complex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re)
        }

        static func + (a: Complex, b: Complex) -> Complex {
            Complex(re: a.re + b.re, im: a.im + b.im)
        }

        static func / (a: Complex, b: Complex) -> Complex {
            let denominator = b.re * b.re + b.im * b.im
            guard denominator > 0 else { return Complex(re: 0, im: 0) }
            return Complex(re: (a.re * b.re + a.im * b.im) / denominator,
                           im: (a.im * b.re - a.re * b.im) / denominator)
        }

        var magnitudeSquared: Float { re * re + im * im }
    }

    static func reflectance(wavelengthNM: Float, layers: [CoatingLayer],
                            substrate: OpticalMaterial,
                            incidentIndex: Float = 1) -> Float {
        let substrateIndex = substrate.index(wavelengthNM: wavelengthNM)
        // [B, C] = M · [1, n_substrate]. With no layers M is the identity and the admittance is
        // the substrate's own, which is the bare Fresnel case.
        var b = Complex(re: 1, im: 0)
        var c = Complex(re: substrateIndex, im: 0)
        for layer in layers.reversed() {
            let index = layer.material.index(wavelengthNM: wavelengthNM)
            let delta = 2 * Float.pi * index * layer.thicknessNM / wavelengthNM
            let cosine = cos(delta), sine = sin(delta)
            // [[cos δ, i sin δ / n], [i n sin δ, cos δ]] applied to (b, c).
            let nextB = Complex(re: cosine, im: 0) * b
                + Complex(re: 0, im: sine / index) * c
            let nextC = Complex(re: 0, im: index * sine) * b
                + Complex(re: cosine, im: 0) * c
            b = nextB
            c = nextC
        }
        let admittance = c / b
        let numerator = Complex(re: incidentIndex - admittance.re, im: -admittance.im)
        let denominator = Complex(re: incidentIndex + admittance.re, im: admittance.im)
        return clamp((numerator / denominator).magnitudeSquared, 0, 1)
    }
}

// MARK: - The filter

/// A single filter element: what absorbs, what it is made of, and what is on its faces.
public struct LensFilter: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// Internal transmittance of the absorbing medium alone, on `SpectralGrid`'s 380–780 nm
    /// axis, with the surface reflections taken out. Kept separate from what a meter would read
    /// through the filter because the surfaces move when the coating does and the dye does not.
    public var internalTransmittance: [Float]
    public var substrate: OpticalMaterial
    public var coating: FilterCoating

    public init(id: String, name: String, internalTransmittance: [Float],
                substrate: OpticalMaterial = .opticalResin,
                coating: FilterCoating = .multiCoated) {
        precondition(internalTransmittance.count == SpectralGrid.count,
                     "a filter's transmittance is stated on the spectral grid")
        self.id = id
        self.name = name
        self.internalTransmittance = internalTransmittance.map { clamp($0, 0, 1) }
        self.substrate = substrate
        self.coating = coating
    }

    /// Reflectance of one face, band by band.
    public var surfaceReflectance: [Float] {
        let layers = coating.layers
        return SpectralGrid.wavelengths.map {
            ThinFilm.reflectance(wavelengthNM: $0, layers: layers, substrate: substrate)
        }
    }

    /// What actually reaches the lens: two surfaces crossed, the dye crossed once, and the
    /// endless series of reflections trapped between the two faces summed —
    /// `(1 − R)² τ / (1 − R² τ²)`. For a clear uncoated crown that is `(1 − R) / (1 + R)`,
    /// the 91.8% every optics text quotes.
    public var transmittance: [Float] {
        let reflectance = surfaceReflectance
        return (0..<SpectralGrid.count).map { i in
            let r = reflectance[i], t = internalTransmittance[i]
            let direct = (1 - r) * (1 - r) * t
            return clamp(direct / max(1 - r * r * t * t, 1e-6), 0, 1)
        }
    }

    /// Returns a linear-Rec.2020 swatch of the filtered visible spectrum. Each wavelength is
    /// normalized by its brightest primary before filter transmission is applied.
    public func spectrumSwatch(samples: Int) -> [SIMD3<Float>] {
        guard samples > 1 else { return [] }
        let transmission = transmittance
        return (0..<samples).map { index in
            let position = Float(index) / Float(samples - 1)
            let wavelength = 380 + position * 400
            let through = SpectralGrid.interpolate(transmission, atWavelength: wavelength)
            var xyz = SIMD3<Float>(
                SpectralGrid.interpolate(SpectralGrid.xBar, atWavelength: wavelength),
                SpectralGrid.interpolate(SpectralGrid.yBar, atWavelength: wavelength),
                SpectralGrid.interpolate(SpectralGrid.zBar, atWavelength: wavelength))
            let peak = max(xyz.x, max(xyz.y, xyz.z))
            if peak > 0 { xyz /= peak }
            // Through P3 because that is the matrix the grid publishes, then into the working
            // space by the seam the rest of the engine uses. Two exact matrices, no third one to
            // keep in step.
            var rgb = ColorScience.linearDisplayP3ToRec2020(
                SpectralGrid.linearDisplayP3(fromXYZ: xyz))
            let brightest = max(rgb.x, max(rgb.y, rgb.z))
            if brightest > 0 { rgb /= brightest }
            return SIMD3(max(rgb.x, 0) * through,
                         max(rgb.y, 0) * through,
                         max(rgb.z, 0) * through)
        }
    }

    /// Photopic transmittance under a stated light — what a meter cell behind the filter loses.
    public func luminousTransmittance(illuminant: [Float] = SpectralGrid.d65) -> Float {
        let filtered = transmittance
        var through: Float = 0, open: Float = 0
        for i in 0..<SpectralGrid.count {
            let weight = illuminant[i] * SpectralGrid.yBar[i]
            open += weight
            through += weight * filtered[i]
        }
        return open > 0 ? through / open : 1
    }
}

// MARK: - Building filters from what they are specified by

extension LensFilter {
    /// Peak internal transmittance of a dyed filter away from its absorption — set by the
    /// substrate and the dye's own residual haze, not by the dye's colour. A clean gelatin or
    /// resin filter passes about 97% of the light its surfaces let in, wherever the dye is out
    /// of the way; that is what makes a #25 red still an 89%-transmitting piece of glass at
    /// 650 nm.
    static let clearInternalTransmittance: Float = 0.97

    /// Builds a colour-conversion filter by solving two subtractive-dye densities that move the
    /// source chromaticity to the target. Warming uses yellow and magenta; cooling uses cyan and
    /// magenta. Filter loss follows from the solved densities.
    public static func conversion(id: String, name: String,
                                  fromKelvin source: Float, toKelvin target: Float,
                                  substrate: OpticalMaterial = .opticalResin,
                                  coating: FilterCoating = .multiCoated) -> LensFilter {
        let warming = target < source
        let dyes: [CCAbsorption] = warming ? [.yellow, .magenta] : [.cyan, .magenta]
        let sourceSPD = Illuminant.atLocus(kelvin: source)
        let targetSPD = Illuminant.atLocus(kelvin: target)
        let densities = solveDyeDensities(source: sourceSPD, target: targetSPD, dyes: dyes)
        return LensFilter(id: id, name: name,
                          internalTransmittance: dyeTransmittance(dyes, densities: densities),
                          substrate: substrate, coating: coating)
    }

    /// Internal transmittance of a set of subtractive dyes at stated densities, over the
    /// substrate's own clear limit.
    static func dyeTransmittance(_ dyes: [CCAbsorption], densities: [Float]) -> [Float] {
        SpectralGrid.wavelengths.map { wavelength in
            var total: Float = 0
            for (dye, density) in zip(dyes, densities) {
                let (centre, width) = dye.band
                let z = (wavelength - centre) / width
                total += density * exp(-0.5 * z * z)
            }
            return clamp(clearInternalTransmittance * pow(10, -total), 0, 1)
        }
    }

    /// The dye densities that carry `source`'s chromaticity onto `target`'s.
    ///
    /// Two dyes, two chromaticity coordinates, one Newton solve with a numerical Jacobian —
    /// damped, and stepped back onto non-negative densities, because a dye cannot emit. The
    /// residual is measured in CIE 1960 uv, which is where the mired scale itself is defined, so
    /// converging here is converging on the filter's published specification.
    static func solveDyeDensities(source: [Float], target: [Float],
                                  dyes: [CCAbsorption]) -> [Float] {
        let goal = uv(of: target)
        var densities = [Float](repeating: 0.2, count: dyes.count)

        func residual(_ d: [Float]) -> SIMD2<Float> {
            let t = dyeTransmittance(dyes, densities: d)
            let through = (0..<SpectralGrid.count).map { source[$0] * t[$0] }
            return uv(of: through) - goal
        }

        for _ in 0..<64 {
            let base = residual(densities)
            if (base.x * base.x + base.y * base.y).squareRoot() < 1e-6 { break }
            // Numerical Jacobian: two columns, one per dye.
            let step: Float = 1e-3
            var j = [SIMD2<Float>](repeating: .zero, count: dyes.count)
            for k in densities.indices {
                var bumped = densities
                bumped[k] += step
                j[k] = (residual(bumped) - base) / step
            }
            let determinant = j[0].x * j[1].y - j[0].y * j[1].x
            guard abs(determinant) > 1e-12 else { break }
            let deltaA = (-base.x * j[1].y + base.y * j[1].x) / determinant
            let deltaB = (-j[0].x * base.y + j[0].y * base.x) / determinant
            // Half steps until the residual actually falls: the map from density to chromaticity
            // is curved, and a full Newton step near zero density overshoots into negatives.
            var scale: Float = 1
            let magnitude = base.x * base.x + base.y * base.y
            for _ in 0..<12 {
                let trial = [max(densities[0] + deltaA * scale, 0),
                             max(densities[1] + deltaB * scale, 0)]
                let next = residual(trial)
                if next.x * next.x + next.y * next.y < magnitude {
                    densities = trial
                    break
                }
                scale *= 0.5
            }
        }
        return densities
    }

    /// CIE 1960 uv of a spectrum — the space the mired scale lives in.
    private static func uv(of spectrum: [Float]) -> SIMD2<Float> {
        let xyz = SpectralGrid.xyz(spectrum: spectrum)
        let denominator = xyz.x + 15 * xyz.y + 3 * xyz.z
        guard denominator > 0 else { return .zero }
        return SIMD2(4 * xyz.x / denominator, 6 * xyz.y / denominator)
    }

    /// Builds a logistic cut-on filter from its half-height wavelength and edge width.
    public static func cutOn(id: String, name: String, halfHeightNM: Float,
                             edgeWidthNM: Float = 8,
                             peakTransmittance: Float? = nil,
                             substrate: OpticalMaterial = .opticalResin,
                             coating: FilterCoating = .multiCoated) -> LensFilter {
        let ceiling = peakTransmittance ?? clearInternalTransmittance
        let values = SpectralGrid.wavelengths.map { wavelength -> Float in
            ceiling / (1 + exp(-(wavelength - halfHeightNM) / max(edgeWidthNM, 0.5)))
        }
        return LensFilter(id: id, name: name, internalTransmittance: values,
                          substrate: substrate, coating: coating)
    }

    /// A band filter — the tricolour separation blue and green, and the deep greens — as a
    /// cut-on and a cut-off in series. Peak transmittance is stated rather than assumed: a dye
    /// narrow enough to pass one third of the spectrum absorbs inside its own passband too, and
    /// these filters are genuinely dark.
    public static func band(id: String, name: String,
                            lowNM: Float, highNM: Float,
                            edgeWidthNM: Float = 12,
                            peakTransmittance: Float,
                            substrate: OpticalMaterial = .opticalResin,
                            coating: FilterCoating = .multiCoated) -> LensFilter {
        let values = SpectralGrid.wavelengths.map { wavelength -> Float in
            let rising = 1 / (1 + exp(-(wavelength - lowNM) / max(edgeWidthNM, 0.5)))
            let falling = 1 / (1 + exp((wavelength - highNM) / max(edgeWidthNM, 0.5)))
            return peakTransmittance * rising * falling
        }
        return LensFilter(id: id, name: name, internalTransmittance: values,
                          substrate: substrate, coating: coating)
    }

    /// Builds a spectrally flat neutral-density filter over the model's 380–780 nm range.
    public static func neutralDensity(_ density: Float,
                                      substrate: OpticalMaterial = .opticalGlassDefault,
                                      coating: FilterCoating = .multiCoated) -> LensFilter {
        let stops = density / 0.30103
        let name = String(format: "ND %.1f (%.0f stop%@)", density, stops.rounded(),
                          stops.rounded() == 1 ? "" : "s")
        let value = clamp(pow(10, -max(density, 0)), 0, 1)
        // The id quantises to tenths of density — "nd03" for a 0.3, "nd30" for a 3.0 — because
        // that is the spelling the app's filter deck fits by and the FOTUFILM_FIT_FILTERS
        // harness passes, and an id that disagrees with them is a filter that silently never
        // resolves. Densities are sold in tenths, so nothing real collides.
        return LensFilter(id: String(format: "nd%02.0f", (density * 10).rounded()), name: name,
                          internalTransmittance: [Float](repeating: value,
                                                         count: SpectralGrid.count),
                          substrate: substrate, coating: coating)
    }

    /// Which band a colour-compensating filter takes its density out of. A CC filter is
    /// specified as a peak density in one of the three subtractive bands — CC30M is 0.30 of
    /// density in the green — and the absorption is a single broad band, not a notch, because
    /// that is what the azo and anthraquinone dyes these are made from do.
    public enum CCAbsorption: String, Sendable, Codable, CaseIterable {
        case yellow, magenta, cyan

        /// Centre and standard deviation of the absorption band, in nanometres.
        var band: (centreNM: Float, widthNM: Float) {
            switch self {
            // Yellow dye absorbs the blue record: a narrow band, since the blue end of the
            // spectrum is narrow.
            case .yellow: return (440, 42)
            // Magenta takes the green out, centred on where the green record peaks.
            case .magenta: return (545, 40)
            // Cyan is the broadest of the three and its band runs off the long end of the
            // visible, which is why a cyan filter looks so much darker than its density says.
            case .cyan: return (660, 62)
            }
        }

        public var label: String { rawValue.capitalized }
    }

    /// A colour-compensating filter: a stated peak density in one subtractive band, or in two of
    /// them for the additive colours (a CC red is a magenta and a yellow laid together, which is
    /// how the Wratten book builds one).
    public static func colorCompensating(_ absorptions: [CCAbsorption], density: Float,
                                         id: String, name: String,
                                         substrate: OpticalMaterial = .opticalResin,
                                         coating: FilterCoating = .multiCoated) -> LensFilter {
        let values = SpectralGrid.wavelengths.map { wavelength -> Float in
            var total: Float = 0
            for absorption in absorptions {
                let (centre, width) = absorption.band
                let z = (wavelength - centre) / width
                total += density * exp(-0.5 * z * z)
            }
            return clamp(clearInternalTransmittance * pow(10, -total), 0, 1)
        }
        return LensFilter(id: id, name: name, internalTransmittance: values,
                          substrate: substrate, coating: coating)
    }

    /// Neodymium-doped intensifier filter. Narrow Nd³⁺ absorption bands, especially at 578 nm,
    /// reduce orange wavelengths between the red and green bands.
    public static func didymium(id: String = "didymium", name: String = "Didymium",
                                strength: Float = 1,
                                substrate: OpticalMaterial = .opticalGlassDefault,
                                coating: FilterCoating = .multiCoated) -> LensFilter {
        // Centre, peak density and width of the visible Nd³⁺ absorptions.
        let lines: [(Float, Float, Float)] = [
            (521, 0.22, 7),
            (578, 0.85, 9),
            (742, 0.55, 12),
        ]
        let values = SpectralGrid.wavelengths.map { wavelength -> Float in
            var total: Float = 0
            for (centre, peak, width) in lines {
                let z = (wavelength - centre) / width
                total += strength * peak * exp(-0.5 * z * z)
            }
            return clamp(clearInternalTransmittance * pow(10, -total), 0, 1)
        }
        return LensFilter(id: id, name: name, internalTransmittance: values,
                          substrate: substrate, coating: coating)
    }
}

extension OpticalMaterial {
    /// The glass a screw-in filter is ground from, named for call sites that do not care which
    /// crown it is.
    public static let opticalGlassDefault = OpticalMaterial.crownGlass
}
