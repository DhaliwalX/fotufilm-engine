import Foundation

/// Image-dye families used by the wavelength-domain output model.
public enum FilmDyeFamily: String, Codable, Sendable {
    case kodakNegative
    case fujiNegative
    case motionNegative
    case kodachrome
    case monochrome
}

/// How a negative is shown when the reader asks for the film instead of the print.
public enum NegativeViewing: String, Sendable, CaseIterable, Identifiable {
    /// Normalised on the viewing light.
    case lightBox = "light-box"
    /// Normalised on the film's own D-min, so the base reads white and what
    /// is left is only the image's inversion.
    case scanner

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .lightBox: "Light Box"
        case .scanner: "Scanner"
        }
    }

    /// A small stable integer for cache identities.
    var ordinal: UInt64 {
        switch self {
        case .lightBox: 0
        case .scanner: 1
        }
    }
}

/// Wavelength-domain description of one film's capture layers and image dyes.
public struct FilmSpectralProfile: Sendable {
    public var layerSensitivity: [[Float]]
    public var imageDyeDensity: [[Float]]

    /// How many capture layers this profile carries. Separate from the dye count on purpose:
    /// a film senses with as many layers as it is coated with and forms three dyes regardless.
    public var captureLayerCount: Int { layerSensitivity.count }

    public init(layerSensitivity: [[Float]], imageDyeDensity: [[Float]]) {
        // The layer bound is the renderer's, not film's — see
        // `FilmStock.supportedCaptureLayerCounts`, which is where the reason lives.
        // `FilmStockDefinition.validate()` reports a stock that exceeds it as a
        // named failure; this precondition is the backstop for profiles built in code.
        precondition(FilmStock.supportedCaptureLayerCounts.contains(layerSensitivity.count),
                     "\(layerSensitivity.count) capture layers; this build renders "
                     + "\(FilmStock.supportedCaptureLayerCounts)")
        precondition(imageDyeDensity.count == FilmStock.dyeCount)
        precondition(layerSensitivity.allSatisfy { $0.count == SpectralGrid.count })
        precondition(imageDyeDensity.allSatisfy { $0.count == SpectralGrid.count })
        self.layerSensitivity = layerSensitivity
        self.imageDyeDensity = imageDyeDensity
    }

    /// Manufacturer-graph sensitivity samples on SpectralGrid's wavelength axis.
    public static func measured(
        layerSensitivity: [[Float]],
        dyeFamily: FilmDyeFamily
    ) -> FilmSpectralProfile {
        precondition(FilmStock.supportedCaptureLayerCounts.contains(layerSensitivity.count))
        precondition(layerSensitivity.allSatisfy { $0.count == SpectralGrid.count })
        let continued = layerSensitivity.map(SpectralGrid.continuedTails)
        return FilmSpectralProfile(
            layerSensitivity: SpectralGrid.normalizeSensitivities(continued),
            imageDyeDensity: SpectralGrid.dyes(family: dyeFamily)
        )
    }

    /// Smooth compatibility approximations for custom profiles without a
    /// retained manufacturer trace.
    public static func color(
        peaksNM: [Float],
        widthsNM: [Float] = [58, 46, 42],
        dyeFamily: FilmDyeFamily
    ) -> FilmSpectralProfile {
        precondition(peaksNM.count == 3 && widthsNM.count == 3)
        let layers = (0..<3).map { layer in
            let sigmas = colorLayerSigmas(layer: layer, widthNM: widthsNM[layer])
            return SpectralGrid.asymmetricGaussian(
                peak: peaksNM[layer],
                leftSigma: sigmas.left,
                rightSigma: sigmas.right
            )
        }
        return FilmSpectralProfile(
            layerSensitivity: SpectralGrid.normalizeSensitivities(layers),
            imageDyeDensity: SpectralGrid.dyes(family: dyeFamily)
        )
    }

    /// How wide one layer's lobe stands on each side of its peak, for a stated bandwidth.
    ///
    /// A red layer is the lopsided one: its sensitising-dye response overlaps the orange band on
    /// the way to its peak, then the emulsion becomes blind quickly past the visible-red edge.
    /// This is public so that an editor showing the shape shows the shape the film will really
    /// have rather than a drawing that resembles it.
    public static func colorLayerSigmas(layer: Int,
                                        widthNM: Float) -> (left: Float, right: Float) {
        (left: widthNM * (layer == 0 ? 0.54 : 0.62),
         right: widthNM * (layer == 0 ? 0.32 : (layer == 2 ? 0.62 : 0.78)))
    }

    /// One layer's sensitivity at one wavelength, on its own peak of 1 — the same lobe `color`
    /// builds from, before the three are normalised together.
    public static func colorLayerSensitivity(layer: Int, peakNM: Float, widthNM: Float,
                                             atNM wavelength: Float) -> Float {
        let sigmas = colorLayerSigmas(layer: layer, widthNM: widthNM)
        let sigma = wavelength < peakNM ? sigmas.left : sigmas.right
        let x = (wavelength - peakNM) / max(sigma, 1)
        return exp(-0.5 * x * x)
    }

    /// Where a panchromatic emulsion's three bands sit, and how wide they are. The weights are
    /// the film's own; these are not.
    public static let monochromeBandsNM: (centres: [Float], widths: [Float]) =
        (centres: [610, 545, 445], widths: [68, 62, 58])

    /// Panchromatic silver response constructed from broad spectral bands.
    public static func monochrome(rgbWeights: [Float]) -> FilmSpectralProfile {
        precondition(rgbWeights.count == 3)
        let centers = monochromeBandsNM.centres
        let widths = monochromeBandsNM.widths
        var response = [Float](repeating: 0, count: SpectralGrid.count)
        for component in 0..<3 {
            let band = SpectralGrid.asymmetricGaussian(
                peak: centers[component], leftSigma: widths[component],
                rightSigma: widths[component])
            for i in response.indices { response[i] += rgbWeights[component] * band[i] }
        }
        let normalized = SpectralGrid.normalizeSensitivities([response, response, response])
        return FilmSpectralProfile(
            layerSensitivity: normalized,
            imageDyeDensity: SpectralGrid.dyes(family: .monochrome)
        )
    }

    /// Compatibility profile for custom stocks created with the historical
    /// RGB sensitivity matrix but no explicit spectral data.
    static func approximation(sensitivity: [[Float]], monochrome: Bool,
                              reversal: Bool) -> FilmSpectralProfile {
        if monochrome {
            return .monochrome(rgbWeights: sensitivity[0])
        }
        return .color(peaksNM: [650, 550, 450],
                      dyeFamily: reversal ? .kodachrome : .kodakNegative)
    }

    var signature: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for v in layerSensitivity.joined() {
            h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3
        }
        for v in imageDyeDensity.joined() {
            h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3
        }
        return h
    }
}

/// A compact three-channel 3D lookup table.
public struct SpectralLUT: Sendable {
    public let dimension: Int
    /// RGBA-interleaved for direct upload into an rgba32Float 3D Metal texture.
    public let values: [Float]

    public init(dimension: Int, values: [Float]) {
        precondition(values.count == dimension * dimension * dimension * 4)
        self.dimension = dimension
        self.values = values
    }

    @inlinable
    public func sample(_ p: SIMD3<Float>) -> SIMD3<Float> {
        values.withUnsafeBufferPointer { Self.sample(p, values: $0.baseAddress!,
                                                     dimension: dimension) }
    }

    @inlinable
    public static func sample(_ p: SIMD3<Float>, values: UnsafePointer<Float>,
                              dimension d: Int) -> SIMD3<Float> {
        // Video decoders and third-party hosts can emit NaN/inf on a failed frame. Keep the LUT's
        // unchecked pointer arithmetic behind a finite-coordinate boundary so malformed input can
        // fail at the adapter without first trapping inside a host process.
        guard d >= 2, p.x.isFinite, p.y.isFinite, p.z.isFinite else { return .zero }
        let q = SIMD3<Float>(
            clamp(p.x, 0, 1) * Float(d - 1),
            clamp(p.y, 0, 1) * Float(d - 1),
            clamp(p.z, 0, 1) * Float(d - 1))
        let x0 = min(Int(q.x), d - 2), y0 = min(Int(q.y), d - 2)
        let z0 = min(Int(q.z), d - 2)
        let f = SIMD3<Float>(q.x - Float(x0), q.y - Float(y0), q.z - Float(z0))

        @inline(__always)
        func load(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
            // One 16-byte read: the table is RGBA-interleaved, so a corner is contiguous and
            // its offset is a multiple of four floats. Three scalar reads fetch the same bytes
            // through three instructions.
            let i = ((z * d + y) * d + x) * 4
            let rgba = UnsafeRawPointer(values + i).loadUnaligned(as: SIMD4<Float>.self)
            return SIMD3(rgba.x, rgba.y, rgba.z)
        }
        // Only the corners the chosen tetrahedron actually interpolates are read. Every branch
        // below touches four of the eight, and two of those four — the cube's near and far
        // corners — are common to all six, so they are the only ones fetched up front. Reading
        // all eight eagerly doubles the memory this function moves, and at 4 MB the table is far
        // too big to be sitting in cache waiting.
        let c000 = load(x0, y0, z0)
        let c111 = load(x0 + 1, y0 + 1, z0 + 1)
        if f.x >= f.y {
            if f.y >= f.z {
                let c100 = load(x0 + 1, y0, z0), c110 = load(x0 + 1, y0 + 1, z0)
                return c000 + f.x * (c100 - c000) + f.y * (c110 - c100)
                     + f.z * (c111 - c110)
            } else if f.x >= f.z {
                let c100 = load(x0 + 1, y0, z0), c101 = load(x0 + 1, y0, z0 + 1)
                return c000 + f.x * (c100 - c000) + f.z * (c101 - c100)
                     + f.y * (c111 - c101)
            } else {
                let c001 = load(x0, y0, z0 + 1), c101 = load(x0 + 1, y0, z0 + 1)
                return c000 + f.z * (c001 - c000) + f.x * (c101 - c001)
                     + f.y * (c111 - c101)
            }
        } else if f.x >= f.z {
            let c010 = load(x0, y0 + 1, z0), c110 = load(x0 + 1, y0 + 1, z0)
            return c000 + f.y * (c010 - c000) + f.x * (c110 - c010)
                 + f.z * (c111 - c110)
        } else if f.y >= f.z {
            let c010 = load(x0, y0 + 1, z0), c011 = load(x0, y0 + 1, z0 + 1)
            return c000 + f.y * (c010 - c000) + f.z * (c011 - c010)
                 + f.x * (c111 - c011)
        } else {
            let c001 = load(x0, y0, z0 + 1), c011 = load(x0, y0 + 1, z0 + 1)
            return c000 + f.z * (c001 - c000) + f.y * (c011 - c001)
                 + f.x * (c111 - c011)
        }
    }
}

/// Runtime tables consumed by both the Swift reference path and Metal.
public struct SpectralPipelineTables: Sendable {
    /// Exposure-domain scene light -> normalized film-layer exposure. The table is indexed in the
    /// locus-enclosing basis returned by `ColorScience.linearRec2020ToExposureDomain`; callers that
    /// sample it directly must convert scene-linear Rec.2020 into that basis first.
    public let exposure: SpectralLUT
    /// Negative: density -> relative log paper exposures.
    public let filmOutput: SpectralLUT
    /// Paper layer density -> display-linear RGB; nil for reversal.
    public let paperOutput: SpectralLUT?
}

/// Builds and caches the LUT acceleration of the wavelength-domain model.
public enum SpectralRuntime {
    public static let lutDimension = 33
    private static let lock = NSCondition()
    /// Bounded, because the key is a hash of the stock's own curves and every custom-film slider
    /// position, aged year and viewing lamp is a stock of its own: a session that keeps every
    /// table set it ever built holds a few megabytes per slider tick until the process is killed
    /// for it. The limit is a working set — the pack on the strip, the medium beside it — and a
    /// miss rebuilds what a drag asked for a hundred positions ago.
    nonisolated(unsafe) private static var cache =
        BoundedCache<UInt64, SpectralPipelineTables>(limit: 40)
    /// Keys a thread is building right now.
    nonisolated(unsafe) private static var building: Set<UInt64> = []
    /// The negative-viewing tables, on their own lock.
    private static let negativeLock = NSLock()
    nonisolated(unsafe) private static var negativeCache =
        BoundedCache<UInt64, SpectralLUT>(limit: 16)
    /// The solved printing balance, on its own lock. `printingContrastScale` is read once per
    /// engine invocation.
    static let balanceLock = NSLock()
    nonisolated(unsafe) static var balanceCache = BoundedCache<UInt64, [Float]>(limit: 256)

    /// Diagnostic: what the process is holding in table sets — how many, and how many bytes of
    /// LUT they come to. Read by the editor soak to watch the cache grow with a session.
    public static var retainedTables: (sets: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        let bytes = cache.allValues.reduce(0) { total, tables in
            total + (tables.exposure.values.count + tables.filmOutput.values.count
                     + (tables.paperOutput?.values.count ?? 0)) * MemoryLayout<Float>.size
        }
        return (cache.count, bytes)
    }

    /// Bucket width for print-viewing temperatures, in kelvin — the same coarseness the
    /// scene-light tables blend on, so a whole viewing session shares one paper table.
    static let printLightBucketKelvin: Float = 100

    /// The print-viewing gate. Nil or a non-positive temperature keeps the medium's reference
    /// illuminant. Named standards retain their specified temperatures; other values are
    /// quantized to `printLightBucketKelvin` so a viewing session shares one table.
    public static func printLightKelvin(_ cct: Float?) -> Float? {
        guard let cct, cct > 0 else { return nil }
        for standard: Float in [2856, 5003, 6504]
            where abs(cct - standard) < printLightBucketKelvin / 2 {
            return standard
        }
        return (cct / printLightBucketKelvin).rounded() * printLightBucketKelvin
    }

    /// The lamp the finished print hangs under. CIE practice: the daylight series where it
    /// is defined (4000 K and up — D50 proofing light, D65, overcast shade), the Planckian
    /// radiator below (halogen and tungsten room light, CIE A at 2856 K). The seam at
    /// 4000 K steps between the two families, which is the CIE's own seam, not a new one.
    static func printLightSPD(kelvin: Float) -> [Float] {
        kelvin >= 4000 ? Illuminant.daylight(kelvin: kelvin)
                       : Illuminant.planckian(kelvin: kelvin)
    }

    /// The illuminant a medium's own calibration is judged under. Digital outputs have no
    /// external viewing lamp; reflection prints use D50 and projection prints use their filtered
    /// xenon reference.
    static func referenceViewingLight(for paper: PrintPaper) -> [Float]? {
        if paper.isProjected { return Illuminant.xenonProjection }
        if paper.acceptsViewingIlluminant { return Illuminant.d50 }
        return nil
    }

    public static func tables(for stock: FilmStock,
                              paper: PrintPaper = .default,
                              bleachBypass: Float = 0,
                              printViewingKelvin: Float? = nil) -> SpectralPipelineTables {
        let bleachBypass = retainedSilverFraction(bleachBypass, stock: stock)
        let printViewingKelvin = (stock.isReversal || !paper.acceptsViewingIlluminant) ? nil
            : printLightKelvin(printViewingKelvin)
        let key = cacheIdentifier(for: stock, paper: paper, bleachBypass: bleachBypass,
                                  printViewingKelvin: printViewingKelvin)
        lock.lock()
        while true {
            if let found = cache.value(for: key) {
                lock.unlock()
                return found
            }
            if building.contains(key) {
                lock.wait()
                continue
            }
            building.insert(key)
            break
        }
        lock.unlock()

        let built = buildTables(for: stock, paper: paper, bleachBypass: bleachBypass,
                                printViewingKelvin: printViewingKelvin)

        lock.lock()
        cache.insert(built, for: key)
        building.remove(key)
        lock.broadcast()
        lock.unlock()
        return built
    }

    /// Where on a colour's ray the reflectance model is evaluated, as the
    /// peak channel of the reconstruction's input.
    static let reconstructionAnchor: Float = 0.25

    /// Direct full-grid reconstruction, exposed for validation and graph tools. `linearRGB` is in
    /// the scene working space, linear Rec.2020.
    public static func reconstructedReflectance(linearRGB: SIMD3<Float>) -> [Float] {
        let rgb = SIMD3(max(linearRGB.x, 0), max(linearRGB.y, 0), max(linearRGB.z, 0))
        let peak = max(rgb.x, rgb.y, rgb.z)
        guard peak > 0 else { return [Float](repeating: 0, count: SpectralGrid.count) }
        guard let model = MeasuredReflectanceTable.shared else {
            return SpectralGrid.wavelengths.map { _ in (rgb.x + rgb.y + rgb.z) / 3 }
        }
        return model.reflectance(rgb)
    }

    /// The visual density of retained developmental silver per unit of dye density it was
    /// developed alongside. Development reduces silver and forms dye in the same proportion —
    /// the silver is the by-product the dye count is written in — and Kodak's own description
    /// of skip-bleach (the ENR-family lab services) is a black-and-white negative of full
    /// weight superimposed on the colour one, so the full-retention figure is one density of
    /// silver per density of dye, scaled by how much of the bleach was skipped.
    static let retainedSilverPerDye: Float = 1

    /// The retained-silver fraction a stock actually honours: monochrome stocks *are* silver
    /// and were never bleached, and a reversal's direct positive keeps its own balance.
    static func retainedSilverFraction(_ requested: Float, stock: FilmStock) -> Float {
        guard !stock.isMonochrome, !stock.isReversal else { return 0 }
        return min(max(requested, 0), 1)
    }

    /// Spectrally flat density of the silver the bleach left behind, for one developed
    /// density triple: proportional to development, which is density above each layer's base.
    static func retainedSilverDensity(_ density: [Float], dMin: [Float],
                                      fraction: Float) -> Float {
        guard fraction > 0 else { return 0 }
        var silver: Float = 0
        for layer in 0..<3 {
            silver += max(density[layer] - dMin[layer], 0)
        }
        return fraction * retainedSilverPerDye * silver
    }

    /// Identity of the tables a stock needs.
    public static func cacheIdentifier(for stock: FilmStock,
                                       paper: PrintPaper = .default,
                                       bleachBypass: Float = 0,
                                       printViewingKelvin: Float? = nil) -> UInt64 {
        var h = stock.spectralProfile.signature
        func add(_ v: Float) { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        // The exposure LUT is normalized against the illuminant this emulsion was balanced for.
        // Two otherwise identical stocks with different native balances must never share it.
        add(stock.referenceIlluminantKelvin)
        for curve in stock.curves {
            add(curve.dMin); add(curve.gamma); add(curve.toe); add(curve.toeWidth)
            add(curve.shoulder); add(curve.shoulderWidth)
            if let secondary = curve.secondary {
                add(1)
                add(secondary.gamma); add(secondary.toe); add(secondary.toeWidth)
                add(secondary.shoulder); add(secondary.shoulderWidth)
            } else {
                add(0)
            }
        }
        add(stock.paperCurve.dMin); add(stock.paperCurve.gamma)
        add(stock.paperCurve.toe); add(stock.paperCurve.toeWidth)
        add(stock.paperCurve.shoulder); add(stock.paperCurve.shoulderWidth)
        add(stock.paperMidDensity)
        h = (h ^ UInt64(stock.isReversal ? 1 : 0)) &* 0x100000001b3
        h = (h ^ UInt64(stock.isMonochrome ? 1 : 0)) &* 0x100000001b3
        h = (h ^ UInt64(stock.isReflectionPrint ? 1 : 0)) &* 0x100000001b3
        if !stock.isReversal {
            for byte in paper.rawValue.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        }
        // Hashed only away from their off positions, so every identity that existed before
        // these levers is exactly the identity it was.
        let bleach = retainedSilverFraction(bleachBypass, stock: stock)
        if bleach > 0 {
            h = (h ^ UInt64(bleach.bitPattern)) &* 0x100000001b3
        }
        if !stock.isReversal, paper.acceptsViewingIlluminant,
           let kelvin = printLightKelvin(printViewingKelvin) {
            h = (h ^ UInt64(kelvin.bitPattern)) &* 0x9E3779B97F4A7C15
        }
        // The donor layer changes the exposure cube's fourth channel; empty adds the zero the
        // fold starts from, so every pre-donor identity is untouched.
        let donor = donorSignature(for: stock)
        if donor != 0 { h = (h ^ donor) &* 0x100000001b3 }
        return h
    }

    private static func buildTables(for stock: FilmStock,
                                    paper: PrintPaper,
                                    bleachBypass: Float = 0,
                                    printViewingKelvin: Float? = nil) -> SpectralPipelineTables {
        let referenceIlluminant = filmReferenceIlluminant(for: stock)
        let exposure = exposureTable(for: stock, illuminant: referenceIlluminant)
        if stock.isReversal {
            let basis = neutralDensityBasis(for: stock)
            func aligned(_ density: [Float]) -> [Float] { basis(density) }
            let balance = reversalBalance(for: stock, aligned: aligned)
            let output = buildDensityLUT(stock: stock) { density in
                let rgb = transmissionRGB(density: aligned(density),
                                          dyes: stock.spectralProfile.imageDyeDensity) * balance
                return SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0))
            }
            return SpectralPipelineTables(exposure: exposure, filmOutput: output,
                                          paperOutput: nil)
        }
        if paper.isNegative {
            return SpectralPipelineTables(
                exposure: exposure,
                filmOutput: negativeViewing(
                    for: stock, look: .lightBox, bleachBypass: bleachBypass),
                paperOutput: nil)
        }

        let printing: SpectralLUT
        if paper.readsLayersDirectly {
            let reading = screenReading(for: stock)
            printing = buildLUT { p in
                SIMD3(interpolate(reading[0], at: p.x),
                      interpolate(reading[1], at: p.y),
                      interpolate(reading[2], at: p.z))
            }
        } else {
            let paperSensitivity = paper.sensitivity
            // A scan's LED emission is folded into its sensor bands, so its lamp
            // is flat; a sheet hangs under the enlarger.
            let lamp = paper.isScan ? SpectralGrid.equalEnergy
                                    : SpectralGrid.enlarger3200K
            let dMin = stock.curves.map(\.dMin)
            let midDensity = (0..<3).map { stock.curves[$0].density(logExposure: 0) }
            // Retained silver darkens the mid-grey too, and the print re-anchors on it — a
            // lab times a skip-bleach negative through its own extra density, so what
            // survives onto the paper is the added contrast and the lost chroma, not a
            // uniformly darker frame.
            let midEnergy = paperExposure(density: midDensity,
                                          dyes: stock.spectralProfile.imageDyeDensity,
                                          lamp: lamp, paperSensitivity: paperSensitivity,
                                          neutralDensity: retainedSilverDensity(
                                              midDensity, dMin: dMin,
                                              fraction: bleachBypass))
            // Dividing each channel by the stock's own mid energy is the
            // per-stock filtration an enlarger operator dials in. A
            // reference-anchored medium is profiled once instead: the frame is
            // still auto-exposed (green stays the stock's own), but red and
            // blue keep the distance this stock's mask and mid-scale colour
            // put between themselves and the reference's — the cast a real
            // minilab leaves in the file.
            let castOffset = referenceCastOffset(midEnergy: midEnergy,
                                                 stock: stock, paper: paper)
            printing = buildDensityLUT(stock: stock) { density in
                let energy = paperExposure(density: density,
                                           dyes: stock.spectralProfile.imageDyeDensity,
                                           lamp: lamp, paperSensitivity: paperSensitivity,
                                           neutralDensity: retainedSilverDensity(
                                               density, dMin: dMin,
                                               fraction: bleachBypass))
                return SIMD3<Float>(
                    log10(max(energy.x, 1e-12) / max(midEnergy.x, 1e-12)),
                    log10(max(energy.y, 1e-12) / max(midEnergy.y, 1e-12)),
                    log10(max(energy.z, 1e-12) / max(midEnergy.z, 1e-12))) + castOffset
            }
        }

        // Integrate all output media through the overlaid dye spectra and observer. Each dye
        // absorbs across multiple display bands. `partition` normalizes the dye sum at every
        // wavelength, so equal densities still transmit `10^-d` and preserve the neutral axis.
        // One range per record: the engine hands over each channel's
        // activation on its own curve, so each is read back through that
        // curve's density range.
        let paperRanges = paper.printCurves(for: stock)
            .map { $0.dMax - $0.dMin }
        // The lamp the finished positive is read under. A reflection print defaults to the D50
        // judging booth used for critical print evaluation. A projected print defaults to the
        // calibrated 5400 K xenon screen light its published dye amounts target. Screen output
        // stays in the renderer's fixed D65 display space, while scans have no viewing lamp.
        //
        // A stated temperature still wins on physical media: asking what a release print looks
        // like on a light table, or what a paper print looks like under tungsten, is a real
        // spectral change rather than a display white-balance control.
        let viewingLight = printViewingKelvin.map(printLightSPD)
            ?? referenceViewingLight(for: paper)
        let paperOutput: SpectralLUT
        if paper.isScan {
            // The scan's output is a digital inversion with no viewing dyes or lamp. Lab Scan
            // and Telecine both characterize their receiver records into display colour; the
            // receiver bands are measurements, not display primaries.
            let calibration = stock.isMonochrome
                ? nil
                : ScanOutputCalibration(paper: paper, stock: stock, exposure: exposure,
                                        printing: printing)
            paperOutput = buildLUT { activation in
                let density = SIMD3(activation.x * paperRanges[0],
                                    activation.y * paperRanges[1],
                                    activation.z * paperRanges[2])
                if let calibration { return calibration(density) }
                let rgb = SIMD3(pow(10, -density.x), pow(10, -density.y),
                                pow(10, -density.z))
                // A monochrome scan carries no chroma to characterize, so the receiver is the
                // programme. A video transfer still delivers it inside Rec.709.
                return paper.deliversRec709
                    ? ColorScience.linearSRGBToDisplayP3(rgb) : rgb
            }
        } else if paper == .screen, !stock.isMonochrome {
            let screenCalibration = ScreenOutputCalibration(stock: stock, exposure: exposure)
            let baseline = buildLUT { activation in
                transmissionRGB(
                    density: [activation.x * paperRanges[0],
                              activation.y * paperRanges[1],
                              activation.z * paperRanges[2]],
                    dyes: PrintPaper.screen.dyes)
            }
            let calibrated = buildLUT { activation in
                screenCalibration(SIMD3(activation.x * paperRanges[0],
                                        activation.y * paperRanges[1],
                                        activation.z * paperRanges[2]))
            }
            paperOutput = smoothCorrection(calibrated, against: baseline)
        } else {
            paperOutput = buildLUT { activation in
                let density = [activation.x * paperRanges[0],
                               activation.y * paperRanges[1],
                               activation.z * paperRanges[2]]
                return transmissionRGB(density: density, dyes: paper.dyes,
                                       flare: paper.viewingFlare,
                                       illuminant: viewingLight)
            }
        }
        return SpectralPipelineTables(exposure: exposure, filmOutput: printing,
                                      paperOutput: paperOutput)
    }

    /// The stock's own neutral density at a log exposure: the mean of its three records.
    static func neutralDensity(_ stock: FilmStock, _ logExposure: Float) -> Float {
        (stock.curves[0].density(logExposure: logExposure)
         + stock.curves[1].density(logExposure: logExposure)
         + stock.curves[2].density(logExposure: logExposure)) / 3
    }

    /// Samples of the density-to-log-exposure map a direct read applies to
    /// each film layer, over that layer's own dMin...dMax.
    private static let screenReadingSamples = 1024

    private static func screenReading(for stock: FilmStock) -> [[Float]] {
        let mid = neutralDensity(stock, 0)
        return (0..<3).map { layer in
            let curve = stock.curves[layer]
            let range = curve.dMax - curve.dMin
            return (0...screenReadingSamples).map { i in
                let density = curve.dMin
                    + range * Float(i) / Float(screenReadingSamples)
                return mid - neutralDensity(stock, curve.logExposure(density: density))
            }
        }
    }

    private static func interpolate(_ table: [Float], at t: Float) -> Float {
        let x = min(max(t, 0), 1) * Float(table.count - 1)
        let low = Int(x)
        let high = min(low + 1, table.count - 1)
        return table[low] + (x - Float(low)) * (table[high] - table[low])
    }

    /// Newton inverse of a three-record spectral response. The response cube is the same
    /// tetrahedrally interpolated table the renderer uses, so this corrects the nonlinear model
    /// rather than fitting a matrix to one exposure level.
    private struct SpectralResponseInverse: Sendable {
        /// Indexed in the exposure table's locus-enclosing basis, as every exposure cube is.
        let response: SpectralLUT

        /// The solve itself walks linear Rec.2020 — the reflectance region a characterisation
        /// recovers, and the cube it clamps to — and steps into the table's basis only to read
        /// the response. A solution beyond Rec.2020 would be a light no reflectance makes,
        /// which is not what a receiver's inversion is asking for.
        private func sample(_ scene: SIMD3<Float>) -> SIMD3<Float> {
            response.sample(ColorScience.linearRec2020ToExposureDomain(scene))
        }

        func solve(target: SIMD3<Float>, initial: SIMD3<Float>) -> SIMD3<Float> {
            var scene = clamped(initial)
            for _ in 0..<8 {
                let recovered = sample(scene)
                let residual = recovered - target
                let cost = dot(residual, residual)
                if cost < 1e-10 { break }

                let epsilon: Float = 1e-3
                var columns = [SIMD3<Float>](repeating: .zero, count: 3)
                for channel in 0..<3 {
                    var low = scene
                    var high = scene
                    low[channel] = max(scene[channel] - epsilon, 0)
                    high[channel] = min(scene[channel] + epsilon, 1)
                    let span = max(high[channel] - low[channel], 1e-6)
                    columns[channel] = (sample(high) - sample(low)) / span
                }
                guard let delta = linearSolve(columns: columns, rhs: residual) else { break }

                var step: Float = 1
                var accepted = false
                for _ in 0..<8 {
                    let candidate = clamped(scene - step * delta)
                    let error = sample(candidate) - target
                    if dot(error, error) < cost {
                        scene = candidate
                        accepted = true
                        break
                    }
                    step *= 0.5
                }
                if !accepted { break }
            }
            return scene
        }

        private func clamped(_ value: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(clamp(value.x, 0, 1), clamp(value.y, 0, 1), clamp(value.z, 0, 1))
        }

        /// Solves a 3×3 system whose matrix is supplied by columns.
        private func linearSolve(columns: [SIMD3<Float>], rhs: SIMD3<Float>)
            -> SIMD3<Float>? {
            let determinant = dot(columns[0], cross(columns[1], columns[2]))
            guard abs(determinant) > 1e-9 else { return nil }
            return SIMD3(dot(rhs, cross(columns[1], columns[2])) / determinant,
                         dot(columns[0], cross(rhs, columns[2])) / determinant,
                         dot(columns[0], cross(columns[1], rhs)) / determinant)
        }

        private func cross(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(lhs.y * rhs.z - lhs.z * rhs.y,
                  lhs.z * rhs.x - lhs.x * rhs.z,
                  lhs.x * rhs.y - lhs.y * rhs.x)
        }

        private func dot(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
            lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
        }
    }

    /// Pulls a colour back to the nearest in-gamut point along the line to its own luminance axis,
    /// which keeps hue and luminance and gives up only the saturation the basis cannot hold.
    static func heldToGamut(_ colour: SIMD3<Float>, luminance: Float) -> SIMD3<Float> {
        var scale: Float = 1
        for channel in 0..<3 where colour[channel] < 0 {
            scale = min(scale, luminance / (luminance - colour[channel]))
        }
        guard scale < 1 else { return colour }
        return SIMD3(repeating: luminance) + scale * (colour - SIMD3(repeating: luminance))
    }

    /// Characterizes a scan's complete response: film capture and development, image dyes, the
    /// receiver bands the machine reads through — a minilab's LEDs, a telecine's RP 180 printing
    /// density — its balance, and the inversion curve. The medium's tone and intended neutral cast
    /// remain the receiver's; only the false assignment of its three measurement bands to
    /// Display-P3 primaries is replaced, which is the job a lab profile or a TAF characterization
    /// does on the machine.
    private struct ScanOutputCalibration: Sendable {
        let inverse: SpectralResponseInverse
        let range: Float
        let deliversRec709: Bool
        /// Where the medium's own clip begins and ends, in output luminance. The video curve is
        /// the shallower of the two and runs out of record separation earlier than a scan whose
        /// inversion uses the whole container, so it starts giving up its chroma sooner.
        let clipInterval: (Float, Float)

        init(paper: PrintPaper, stock: FilmStock, exposure: SpectralLUT,
             printing: SpectralLUT) {
            let curve = paper.printCurve(for: stock)
            let scanRange = curve.dMax - curve.dMin
            range = scanRange
            deliversRec709 = paper.deliversRec709
            clipInterval = paper == .telecine ? (0.76, 0.84) : (0.78, 0.86)
            let midpoint = curve.logExposure(
                density: curve.dMin + paper.anchorDensity(stock.paperMidDensity))
            let masking = stock.printingContrastScale(
                correction: FotufilmEngine.Options().printCorrection, paper: paper)
            let filmRanges = stock.curves.map { $0.dMax - $0.dMin }
            let response = SpectralRuntime.buildLUT { scene in
                let records = exposure.sample(scene) / 0.18
                let filmDensity = (0..<3).map { channel in
                    stock.curves[channel].density(
                        logExposure: log10(max(records[channel], 1e-6)))
                }
                let activation = SIMD3<Float>((0..<3).map { channel in
                    (filmDensity[channel] - stock.curves[channel].dMin)
                        / filmRanges[channel]
                })
                let receiver = printing.sample(activation)
                return SIMD3<Float>((0..<3).map { channel in
                    curve.density(logExposure: midpoint + masking[channel]
                                  * receiver[channel]) - curve.dMin
                }) / scanRange
            }
            inverse = SpectralResponseInverse(response: response)
        }

        func callAsFunction(_ density: SIMD3<Float>) -> SIMD3<Float> {
            let activation = density / range
            let uncalibrated = SIMD3(pow(10, -density.x), pow(10, -density.y),
                                     pow(10, -density.z))
            var initial = ColorScience.linearDisplayP3ToRec2020(uncalibrated)
            initial = SIMD3(clamp(initial.x, 0, 1), clamp(initial.y, 0, 1),
                            clamp(initial.z, 0, 1))
            let scene = inverse.solve(target: activation, initial: initial)
            var calibrated = ColorScience.linearRec2020ToDisplayP3(scene)
            let weights = ColorScience.displayP3LuminanceWeights
            func luminance(_ value: SIMD3<Float>) -> Float {
                weights.0 * value.x + weights.1 * value.y + weights.2 * value.z
            }

            // Reapply the medium's own balance at the recovered tone level. This retains its
            // intentional stock-dependent neutral cast without letting the receiver bands define
            // the hue of chromatic subjects.
            let sceneLuminance = clamp(luminance(calibrated), 0, 1)
            let neutralDensity = inverse.response.sample(
                SIMD3(repeating: sceneLuminance)) * range
            let neutralReceiver = SIMD3(pow(10, -neutralDensity.x),
                                        pow(10, -neutralDensity.y),
                                        pow(10, -neutralDensity.z))
            calibrated *= neutralReceiver / max(luminance(neutralReceiver), 1e-6)
            let recoveredLuminance = luminance(calibrated)
            guard recoveredLuminance > 1e-6 else { return uncalibrated }

            calibrated = SpectralRuntime.heldToGamut(calibrated,
                                                     luminance: recoveredLuminance)
            if deliversRec709 {
                // A video transfer leaves the machine as a Rec.709 signal, which cannot carry
                // colour outside those primaries. Hold the timed colour at that boundary in 709
                // before delivering it on the engine's wider P3 basis, instead of shipping a
                // saturation the container never had.
                let rec709 = ColorScience.linearDisplayP3ToSRGB(calibrated)
                let held = SpectralRuntime.heldToGamut(
                    rec709, luminance: recoveredLuminance)
                calibrated = ColorScience.linearSRGBToDisplayP3(held)
            }
            let outputLuminance = luminance(uncalibrated)
            calibrated *= outputLuminance / recoveredLuminance

            // The receiver's toe and shoulder densities hold no invertible chromatic signal, so
            // the characterization is faded out at both ends. It fades to the neutral axis rather
            // than to the raw receiver: a machine times its own black and white points, and the
            // receiver is not itself neutral there — a telecine's 430 nm band reads the mask into
            // a blue clip if it is handed the ends. The shadow transition follows this curve's own
            // black floor so it finishes at the floor rather than below it.
            let blackFloor = pow(10, -range)
            let shadow = clamp((blackFloor * 2 - outputLuminance)
                                   / (blackFloor * 2 - blackFloor * 1.5), 0, 1)
            let highlight = clamp((outputLuminance - clipInterval.0)
                                      / (clipInterval.1 - clipInterval.0), 0, 1)
            let endpoint = max(shadow, highlight)
            let hold = endpoint * endpoint * (3 - 2 * endpoint)
            return calibrated
                + hold * (SIMD3(repeating: outputLuminance) - calibrated)
        }
    }

    /// Characterizes the three film records back to the colourimetric scene basis before Screen
    /// displays them. A record is a broad spectral measurement, not a display primary: treating
    /// its red and green exposures as P3 red and green preserves greys but rotates saturated
    /// yellow toward green. Inverting the stock's exact three-dimensional exposure cube resolves
    /// that nonlinear measurement while preserving neutral white exactly.
    private struct ScreenOutputCalibration: Sendable {
        let screenCurve: CharacteristicCurve
        let screenMid: Float
        let neutralMid: Float
        let logExposureLow: Float
        let logExposureHigh: Float
        let neutralDensityTable: [Float]
        let inverse: SpectralResponseInverse
        let captureToRec2020: [SIMD3<Float>]

        private static let inverseSamples = 4096

        init(stock: FilmStock, exposure: SpectralLUT) {
            screenCurve = stock.paperCurve
            screenMid = screenCurve.logExposure(
                density: screenCurve.dMin + PrintPaper.screen.anchorDensity(
                    stock.paperMidDensity))
            neutralMid = SpectralRuntime.neutralDensity(stock, 0)
            let low = stock.curves.map { $0.toe - 6 }.min() ?? -8
            let high = stock.curves.map { $0.shoulder + 6 }.max() ?? 8
            logExposureLow = low
            logExposureHigh = high
            neutralDensityTable = (0...Self.inverseSamples).map { sample in
                let fraction = Float(sample) / Float(Self.inverseSamples)
                return SpectralRuntime.neutralDensity(
                    stock, low + fraction * (high - low))
            }
            inverse = SpectralResponseInverse(response: exposure)
            let profile = CameraSpectralProfile(
                id: "film-screen-\(stock.name)",
                gridSensitivity: Array(stock.spectralProfile.layerSensitivity.prefix(3)))
            captureToRec2020 = profile.matrixToRec2020()
        }

        func callAsFunction(_ density: SIMD3<Float>) -> SIMD3<Float> {
            let uncalibrated = SpectralRuntime.transmissionRGB(
                density: [density.x, density.y, density.z],
                dyes: PrintPaper.screen.dyes, flare: PrintPaper.screen.viewingFlare)
            let relative = SIMD3<Float>((0..<3).map { channel in
                screenCurve.logExposure(density: screenCurve.dMin + density[channel])
                    - screenMid
            })
            let records = SIMD3<Float>((0..<3).map { channel in
                pow(10, logExposure(neutralDensity: neutralMid - relative[channel]))
            })
            let rec2020 = inverseScene(records: records)
            var calibrated = ColorScience.linearRec2020ToDisplayP3(rec2020)
            let weights = ColorScience.displayP3LuminanceWeights
            func luminance(_ value: SIMD3<Float>) -> Float {
                weights.0 * value.x + weights.1 * value.y + weights.2 * value.z
            }
            let uncalibratedSpread = max(uncalibrated.x, uncalibrated.y, uncalibrated.z)
                - min(uncalibrated.x, uncalibrated.y, uncalibrated.z)
            let outputLuminance = luminance(uncalibrated)
            let neutral = SIMD3<Float>(repeating: outputLuminance)
            let recoveredLuminance = luminance(calibrated)
            guard recoveredLuminance > 1e-6 else { return neutral }

            // Bring a colour outside Display P3 toward its own luminance axis until its first
            // negative component reaches zero. This retains luminance and hue direction instead
            // of independently clipping channels at the display boundary.
            var gamutScale: Float = 1
            for channel in 0..<3 where calibrated[channel] < 0 {
                gamutScale = min(gamutScale,
                                 recoveredLuminance
                                     / (recoveredLuminance - calibrated[channel]))
            }
            calibrated = SIMD3(repeating: recoveredLuminance)
                + gamutScale * (calibrated - SIMD3(repeating: recoveredLuminance))
            calibrated *= outputLuminance / recoveredLuminance

            // This stage corrects the receiver's hue; it must not manufacture an entirely new
            // saturated colour. Constrained inverse solutions can otherwise land on different
            // RGB cube faces in adjacent cells, and luminance normalization amplifies the jump.
            let calibratedSpread = max(calibrated.x, calibrated.y, calibrated.z)
                - min(calibrated.x, calibrated.y, calibrated.z)
            let maximumSpread = uncalibratedSpread * 1.2
            if calibratedSpread > maximumSpread {
                calibrated = neutral + (maximumSpread / calibratedSpread)
                    * (calibrated - neutral)
            }
            let colourCorrection = calibrated - uncalibrated
            let correctionMagnitude = max(
                abs(colourCorrection.x), abs(colourCorrection.y),
                abs(colourCorrection.z))
            let maximumCorrection = uncalibratedSpread * 0.11
            if correctionMagnitude > maximumCorrection {
                calibrated = uncalibrated
                    + (maximumCorrection / correctionMagnitude) * colourCorrection
            }

            // The inverse is ill-conditioned around neutral in deep shadows. A hard cutoff here
            // made adjacent LUT cells alternate between neutral and fully reconstructed chroma,
            // which showed as blue contours in smooth dark gradients. Ease across the same
            // uncertainty range while keeping the receiver's luminance fixed.
            let chroma = clamp((uncalibratedSpread - 0.003) / (0.009 - 0.003), 0, 1)
            let chromaWeight = chroma * chroma * (3 - 2 * chroma)
            calibrated = neutral + chromaWeight * (calibrated - neutral)

            // Once the negative is in its shoulder, tiny record differences no longer carry
            // trustworthy chroma. Fade the inverse before that ill-conditioned region can turn
            // interpolation noise into coloured highlights; the original neutral receiver owns
            // the clipped end of Screen's tone scale.
            let highlight = clamp((outputLuminance - 0.76) / (0.84 - 0.76), 0, 1)
            let hold = highlight * highlight * (3 - 2 * highlight)
            return calibrated + hold * (uncalibrated - calibrated)
        }

        private func logExposure(neutralDensity target: Float) -> Float {
            if target <= neutralDensityTable[0] { return logExposureLow }
            if target >= neutralDensityTable[neutralDensityTable.count - 1] {
                return logExposureHigh
            }
            var low = 0
            var high = neutralDensityTable.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if neutralDensityTable[middle] < target { low = middle } else { high = middle }
            }
            let span = neutralDensityTable[high] - neutralDensityTable[low]
            let fraction = span > 1e-8 ? (target - neutralDensityTable[low]) / span : 0
            let position = (Float(low) + fraction) / Float(Self.inverseSamples)
            return logExposureLow + position * (logExposureHigh - logExposureLow)
        }

        /// Inverts the exact stock exposure cube used by the renderer. The least-squares matrix is
        /// only the initial estimate; three-dimensional Newton refinement resolves the nonlinear
        /// spectral reconstruction, which a matrix alone cannot undo near saturated yellow.
        private func inverseScene(records: SIMD3<Float>) -> SIMD3<Float> {
            let recordPeak = max(records.x, records.y, records.z)
            guard recordPeak > 1e-8 else { return .zero }
            let recordFloor = min(records.x, records.y, records.z)
            if (recordPeak - recordFloor) / recordPeak < 1e-4 {
                return SIMD3(repeating: SpectralRuntime.reconstructionAnchor)
            }
            let target = records * (SpectralRuntime.reconstructionAnchor / recordPeak)
            var scene = SIMD3(dot(captureToRec2020[0], target),
                              dot(captureToRec2020[1], target),
                              dot(captureToRec2020[2], target))
            scene = SIMD3(clamp(scene.x, 0, 1), clamp(scene.y, 0, 1),
                          clamp(scene.z, 0, 1))
            if max(scene.x, scene.y, scene.z) < 1e-6 {
                scene = SIMD3(repeating: SpectralRuntime.reconstructionAnchor)
            }

            return inverse.solve(target: target, initial: scene)
        }

        private func dot(_ row: SIMD3<Float>, _ value: SIMD3<Float>) -> Float {
            row.x * value.x + row.y * value.y + row.z * value.z
        }
    }

    /// The negative's own dyes viewed by transmission: density -> display RGB, which is the same
    /// integration `buildTables` gives a transparency, run over a stock that would otherwise have
    /// gone to paper.
    public static func negativeViewing(for stock: FilmStock,
                                       look: NegativeViewing,
                                       bleachBypass: Float = 0) -> SpectralLUT {
        let bleach = retainedSilverFraction(bleachBypass, stock: stock)
        var key = stock.spectralProfile.signature
            ^ (look.ordinal &* 0x9E3779B97F4A7C15)
            ^ densitySignature(of: stock)
        if bleach > 0 {
            key = (key ^ UInt64(bleach.bitPattern)) &* 0x100000001b3
        }
        negativeLock.lock()
        defer { negativeLock.unlock() }
        if let found = negativeCache.value(for: key) { return found }

        let dyes = stock.spectralProfile.imageDyeDensity
        let dMin = stock.curves.map(\.dMin)
        let ranges = stock.curves.map { $0.dMax - $0.dMin }
        let divisor: SIMD3<Float>
        switch look {
        case .lightBox:
            divisor = SIMD3(repeating: 1)
        case .scanner:
            // The base carries no development, so the divisor is silver-free
            // whatever the bleach did: only the image inverts, as before.
            let base = transmissionRGB(density: dMin, dyes: dyes)
            divisor = SIMD3(max(base.x, 1e-6), max(base.y, 1e-6),
                            max(base.z, 1e-6))
        }

        // Indexed by the negative's own activation, because the kernel hands it the negative's
        // own density: FOTUFILM_CONFIG_DEVELOP_COMPLEMENT is zero here, so nothing was inverted
        // upstream and nothing is inverted back. The picture comes out a negative because a
        // negative's dyes are what the transmission is integrated through.
        let table = buildLUT { p in
            let density = [
                dMin[0] + p.x * ranges[0],
                dMin[1] + p.y * ranges[1],
                dMin[2] + p.z * ranges[2],
            ]
            let rgb = transmissionRGB(
                density: density, dyes: dyes,
                neutralDensity: retainedSilverDensity(density, dMin: dMin,
                                                      fraction: bleach)) / divisor
            return SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0))
        }
        negativeCache.insert(table, for: key)
        return table
    }

    /// The curve endpoints the table is built over, so a pack edit that moves D-min or D-max cannot
    /// be served a table built for the old ones.
    private static func densitySignature(of stock: FilmStock) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for curve in stock.curves {
            for value in [curve.dMin, curve.dMax] {
                h = (h ^ UInt64(value.bitPattern)) &* 0x100000001b3
            }
        }
        return h
    }

    /// What a direct positive's developed dyes are divided by before they are shown, per layer.
    private static func reversalBalance(
        for stock: FilmStock, aligned: ([Float]) -> [Float]
    ) -> SIMD3<Float> {
        let dyes = stock.spectralProfile.imageDyeDensity
        let mid = aligned((0..<3).map {
            stock.developedDensity(layer: $0, logExposure: 0)
        })
        let rawMid = transmissionRGB(density: mid, dyes: dyes)
        let balance = SIMD3<Float>(0.18 / max(rawMid.x, 1e-6),
                                   0.18 / max(rawMid.y, 1e-6),
                                   0.18 / max(rawMid.z, 1e-6))
        guard stock.isReflectionPrint else { return balance }
        let white = transmissionRGB(
            density: aligned(stock.curves.map(\.dMin)), dyes: dyes) * balance
        // The transmission is integrated to Display P3 — the print side's basis — so its
        // luminance reads with the P3 weights, not the scene working space's.
        let weights = ColorScience.displayP3LuminanceWeights
        let level = weights.0 * white.x + weights.1 * white.y
            + weights.2 * white.z
        return balance / max(level, 1e-6)
    }

    /// Per-layer map carrying a reversal stock's published Status A densities
    /// onto the density basis the image-dye model reads.
    struct NeutralDensityBasis: Sendable {
        /// Per layer: constant through third order in published density. The cubic term is
        /// needed by source curves with two independently shaped positive components; a
        /// quadratic leaves their neutral records visibly separated through the bend.
        var coefficients: [SIMD4<Float>]

        func callAsFunction(_ density: [Float]) -> [Float] {
            (0..<3).map { layer in
                let c = coefficients[layer]
                let d = density[layer]
                return max(c.x + c.y * d + c.z * d * d + c.w * d * d * d, 0)
            }
        }
    }

    static func neutralDensityBasis(for stock: FilmStock) -> NeutralDensityBasis {
        let termCount = stock.isReflectionPrint ? 4 : 3
        var normal = [[Double]](repeating: [Double](repeating: 0, count: 16), count: 3)
        var moment = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
        for logExposure in stride(from: Float(-1.5), through: 0.75, by: 0.025) {
            let density = (0..<3).map {
                stock.developedDensity(layer: $0, logExposure: logExposure)
            }
            let neutral = Double(density[0] + density[1] + density[2]) / 3
            let weight = pow(10.0, -neutral)
            for layer in 0..<3 {
                let d = Double(density[layer])
                let terms = [1, d, d * d, d * d * d]
                for row in 0..<termCount {
                    for column in 0..<termCount {
                        normal[layer][row * 4 + column]
                            += weight * terms[row] * terms[column]
                    }
                    moment[layer][row] += weight * terms[row] * neutral
                }
            }
        }
        let coefficients = (0..<3).map { layer in
            solve(normal[layer], moment[layer], termCount: termCount)
                ?? SIMD4<Float>(0, 1, 0, 0)
        }
        return NeutralDensityBasis(coefficients: coefficients)
    }

    /// Gaussian elimination with partial pivoting on the normal equations. Rows retain a
    /// four-value stride so reflection prints can use the cubic term while transparencies keep
    /// their established quadratic basis.
    private static func solve(
        _ matrix: [Double], _ rhs: [Double], termCount: Int
    ) -> SIMD4<Float>? {
        var a = matrix, b = rhs
        for column in 0..<termCount {
            var pivot = column
            for row in (column + 1)..<termCount
            where abs(a[row * 4 + column]) > abs(a[pivot * 4 + column]) {
                pivot = row
            }
            guard abs(a[pivot * 4 + column]) > 1e-12 else { return nil }
            if pivot != column {
                for k in 0..<termCount { a.swapAt(column * 4 + k, pivot * 4 + k) }
                b.swapAt(column, pivot)
            }
            for row in (column + 1)..<termCount {
                let factor = a[row * 4 + column] / a[column * 4 + column]
                guard factor != 0 else { continue }
                for k in column..<termCount {
                    a[row * 4 + k] -= factor * a[column * 4 + k]
                }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: 4)
        for row in stride(from: termCount - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<termCount { sum -= a[row * 4 + k] * x[k] }
            x[row] = sum / a[row * 4 + row]
        }
        return SIMD4<Float>(Float(x[0]), Float(x[1]), Float(x[2]), Float(x[3]))
    }

    /// Evaluates the model over the 33³ grid. `fourth` fills the node's spare fourth float —
    /// the donor capture layer's exposure, on the tables that carry one — and nil leaves the
    /// constant 1 the slot has always held, bit for bit.
    private static func buildLUT(_ evaluate: (SIMD3<Float>) -> SIMD3<Float>,
                                 fourth: ((SIMD3<Float>) -> Float)? = nil) -> SpectralLUT {
        let d = lutDimension
        var values = [Float](repeating: 0, count: d * d * d * 4)
        values.withUnsafeMutableBufferPointer { buffer in
            withoutActuallyEscaping(evaluate) { evaluate in
                DispatchQueue.concurrentPerform(iterations: d) { z in
                    for y in 0..<d {
                        for x in 0..<d {
                            let p = SIMD3<Float>(Float(x) / Float(d - 1),
                                                 Float(y) / Float(d - 1),
                                                 Float(z) / Float(d - 1))
                            let v = evaluate(p)
                            let i = ((z * d + y) * d + x) * 4
                            buffer[i] = v.x; buffer[i + 1] = v.y
                            buffer[i + 2] = v.z
                            buffer[i + 3] = fourth?(p) ?? 1
                        }
                    }
                }
            }
        }
        return SpectralLUT(dimension: d, values: values)
    }

    private static func buildDensityLUT(
        stock: FilmStock,
        _ evaluate: ([Float]) -> SIMD3<Float>
    ) -> SpectralLUT {
        let ranges = stock.curves.map { $0.dMax - $0.dMin }
        return buildLUT { p in
            evaluate([
                stock.curves[0].dMin + p.x * ranges[0],
                stock.curves[1].dMin + p.y * ranges[1],
                stock.curves[2].dMin + p.z * ranges[2],
            ])
        }
    }

    /// Low-pass the colour-characterization correction rather than the output itself. The
    /// receiver's tone scale remains exact while isolated inverse solutions cannot become a
    /// visible cell in the delivered 3D LUT.
    private static func smoothCorrection(
        _ calibrated: SpectralLUT, against baseline: SpectralLUT
    ) -> SpectralLUT {
        precondition(calibrated.dimension == baseline.dimension)
        let d = calibrated.dimension
        var values = calibrated.values
        values.withUnsafeMutableBufferPointer { destination in
            DispatchQueue.concurrentPerform(iterations: d) { z in
                for y in 0..<d {
                    for x in 0..<d {
                        let coordinate = SIMD3(x, y, z)
                        let centre = ((z * d + y) * d + x) * 4
                        for channel in 0..<3 {
                            let centreCorrection = calibrated.values[centre + channel]
                                - baseline.values[centre + channel]
                            var neighbourCorrection: Float = 0
                            var neighbourCount: Float = 0
                            for axis in 0..<3 {
                                for offset in [-1, 1] {
                                    var neighbour = coordinate
                                    neighbour[axis] += offset
                                    guard neighbour[axis] >= 0, neighbour[axis] < d else {
                                        continue
                                    }
                                    let index = ((neighbour.z * d + neighbour.y) * d
                                                 + neighbour.x) * 4 + channel
                                    neighbourCorrection += calibrated.values[index]
                                        - baseline.values[index]
                                    neighbourCount += 1
                                }
                            }
                            let averaged = neighbourCorrection / max(neighbourCount, 1)
                            destination[centre + channel] = baseline.values[centre + channel]
                                + 0.5 * (centreCorrection + averaged)
                        }
                        destination[centre + 3] = calibrated.values[centre + 3]
                    }
                }
            }
        }
        return SpectralLUT(dimension: d, values: values)
    }

    /// The fixed illuminant this emulsion was balanced under. This is a property of the stock,
    /// not an automatic white-balance estimate and not a digital RGB adaptation.
    static func filmReferenceIlluminant(for stock: FilmStock) -> [Float] {
        Illuminant.atLocus(kelvin: stock.referenceIlluminantKelvin)
    }

    /// Film-layer exposure for a scene colour: the reflectance model
    /// evaluated once per *chromaticity*, at `reconstructionAnchor`, and
    /// scaled back out. `illuminant` is the scene light the layers integrate
    /// against; D65 is the default scene light, while the denominator remains stock-native.
    static func anchoredExposure(_ rgb: SIMD3<Float>, stock: FilmStock,
                                 illuminant: [Float] = SpectralGrid.d65,
                                 referenceIlluminant: [Float]? = nil,
                                 filter: SpectralFilter? = nil) -> SIMD3<Float> {
        let peak = max(rgb.x, rgb.y, rgb.z)
        guard peak > 0 else { return SIMD3(repeating: 0) }
        let radiance = peak / reconstructionAnchor
        return spectralExposure(rgb / radiance, stock: stock,
                                illuminant: illuminant,
                                referenceIlluminant: referenceIlluminant,
                                filter: filter) * radiance
    }

    /// Exposure is calibrated against the stock's native reference illuminant. The numerator uses
    /// the scene's
    /// actual SPD, so a spectrally flat subject changes the relative record exposures under a
    /// different illuminant just as a daylight-balanced film does. Both SPDs are normalized at
    /// 560 nm so their arbitrary tabular scale is not mistaken for a change in scene intensity.
    /// A lens filter in the form this integration wants it: the stack's transmittance on the
    /// grid, the exposure scale the shoot's metering applied, and the per-layer ratio the
    /// compact fallback needs when there is no reconstruction model to filter band by band.
    /// Built once per exposure table rather than per sample.
    struct SpectralFilter {
        var transmittance: [Float]
        var gain: Float
        var layerRatio: SIMD3<Float>
    }

    /// Layer exposure under a stated light, optionally through a filter.
    ///
    /// The filter and the scene illuminant multiply the numerator; the emulsion's fixed calibration
    /// denominator stays fixed. Their light loss and record imbalance therefore survive into
    /// exposure. The metering scale in `gain` is the only compensation applied here.
    static func spectralExposure(_ rgb: SIMD3<Float>, stock: FilmStock,
                                 illuminant: [Float] = SpectralGrid.d65,
                                 referenceIlluminant suppliedReference: [Float]? = nil,
                                 filter: SpectralFilter? = nil) -> SIMD3<Float> {
        let referenceIlluminant = suppliedReference ?? filmReferenceIlluminant(for: stock)
        precondition(illuminant.count == SpectralGrid.count)
        precondition(referenceIlluminant.count == SpectralGrid.count)
        guard let model = MeasuredReflectanceTable.shared else {
            // The compact fallback was fitted against the P3 basis, so the working-space
            // colour steps back through the seam matrix before the dot. With no spectrum to
            // filter band by band, the filter can only land as the per-layer ratio it works
            // out to under this light — exact for a neutral reflectance, and an approximation
            // for a saturated one, which is the same trade the fallback already makes.
            let s = stock.sensitivity
            let p3 = ColorScience.linearRec2020ToDisplayP3(rgb)
            let plain = SIMD3(dot(s[0], p3), dot(s[1], p3), dot(s[2], p3))
            let anchor = max(illuminant[Illuminant.anchorIndex], 1e-12)
            let referenceAnchor = max(referenceIlluminant[Illuminant.anchorIndex], 1e-12)
            var sceneIntegral = SIMD3<Float>(repeating: 0)
            var referenceIntegral = SIMD3<Float>(repeating: 0)
            for i in 0..<SpectralGrid.count {
                let light = illuminant[i] / anchor
                let reference = referenceIlluminant[i] / referenceAnchor
                for layer in 0..<3 {
                    sceneIntegral[layer] += light * stock.spectralProfile.layerSensitivity[layer][i]
                    referenceIntegral[layer] += reference
                        * stock.spectralProfile.layerSensitivity[layer][i]
                }
            }
            let denominator = SIMD3(max(referenceIntegral.x, 1e-12),
                                    max(referenceIntegral.y, 1e-12),
                                    max(referenceIntegral.z, 1e-12))
            let illuminantRatio = sceneIntegral / denominator
            guard let filter else { return plain * illuminantRatio }
            return plain * illuminantRatio * filter.layerRatio * filter.gain
        }
        let reflectance = model.reflectance(rgb)
        var exposure = SIMD3<Float>(repeating: 0)
        var referenceExposure = SIMD3<Float>(repeating: 0)
        let anchor = max(illuminant[Illuminant.anchorIndex], 1e-12)
        let referenceAnchor = max(referenceIlluminant[Illuminant.anchorIndex], 1e-12)
        for i in 0..<SpectralGrid.count {
            let light = illuminant[i] / anchor
            let referenceLight = referenceIlluminant[i] / referenceAnchor
            let through = filter.map { reflectance[i] * $0.transmittance[i] } ?? reflectance[i]
            exposure.x += through * light * stock.spectralProfile.layerSensitivity[0][i]
            exposure.y += through * light * stock.spectralProfile.layerSensitivity[1][i]
            exposure.z += through * light * stock.spectralProfile.layerSensitivity[2][i]
            referenceExposure.x += referenceLight * stock.spectralProfile.layerSensitivity[0][i]
            referenceExposure.y += referenceLight * stock.spectralProfile.layerSensitivity[1][i]
            referenceExposure.z += referenceLight * stock.spectralProfile.layerSensitivity[2][i]
        }
        let gain = filter?.gain ?? 1
        return SIMD3(gain * exposure.x / max(referenceExposure.x, 1e-12),
                     gain * exposure.y / max(referenceExposure.y, 1e-12),
                     gain * exposure.z / max(referenceExposure.z, 1e-12))
    }

    private static func dot(_ row: [Float], _ rgb: SIMD3<Float>) -> Float {
        row[0] * rgb.x + row[1] * rgb.y + row[2] * rgb.z
    }

    // MARK: - The exposure table's domain

    /// A cell of the exposure table, read as the light it stands for. The table is indexed in a
    /// basis whose chromaticity triangle encloses the spectral locus (`ColorScience
    /// .linearRec2020ToExposureDomain`), and what a cell holds depends on where its colour
    /// lies: inside the Rec.2020 cube it is a reflectance under the scene's light, recovered
    /// from the measured prior exactly as before; outside the cube but inside the locus it is
    /// a real light no reflectance can reach, and beyond the locus there is no light at all.
    enum SceneLight {
        /// A colour the reflectance prior covers, negatives of rounding size clamped away.
        case reflectance(SIMD3<Float>)
        /// A colour of non-positive luminance: darkness.
        case none
        /// A colour just past the cube's face, within the margin: the reflectance model
        /// continued by its own slope, from the face point and its mirror image inside.
        case extrapolated(face: SIMD3<Float>, mirror: SIMD3<Float>)
        /// A colour past the margin, as the mixture that stands for it.
        case locus(LocusLight)
    }

    /// The reflectance model continued by its own slope across the face: the face point's
    /// exposure plus the step from the mirror point inside the cube to the face, which is the
    /// same first derivative on both sides. The old boundary held the face value flat across
    /// every cell outside — a slope break that tetrahedral interpolation carried into the
    /// in-gamut colours next to it.
    static func extrapolatedExposure(face: SIMD3<Float>, mirror: SIMD3<Float>) -> SIMD3<Float> {
        let continued = face * 2 - mirror
        return SIMD3(max(continued.x, 0), max(continued.y, 0), max(continued.z, 0))
    }

    /// The donor record's single value, continued the same way.
    static func extrapolatedExposure(face: Float, mirror: Float) -> Float {
        max(face * 2 - mirror, 0)
    }

    /// A colour beyond the margin outside the Rec.2020 cube, modelled as the reflectance model's
    /// continuation at the margin mixed with monochromatic light at the hue's dominant
    /// wavelength, just enough of it to reach the stated chromaticity. The mixture is linear
    /// in the spectrum, so its layer exposures are the same mixture of the two lights'
    /// exposures; at the margin the monochromatic share is zero and the table continues
    /// without a step. It is steeper outside than in: monochromatic light moves the layers
    /// further per unit of chromaticity than any reflectance can, which is the physics, not a
    /// seam — and the margin keeps that steepness out of every in-gamut interpolation cell.
    struct LocusLight {
        /// The cube-edge colour of the same hue and luminance, linear Rec.2020.
        let face: SIMD3<Float>
        /// The face's mirror image of the margin point, inside the cube.
        let mirror: SIMD3<Float>
        /// The colour's CIE luminance, which the monochromatic light is scaled to as well.
        let luminance: Float
        /// The two observer bands whose mixture sits on the locus at this hue, as grid
        /// indices; across the purple line they are the locus's two ends.
        let lowerBand: Int
        let upperBand: Int
        /// The upper band's share of that mixture's luminance.
        let upperShare: Float
        /// The share of the colour's luminance the monochromatic light supplies: 0 at the
        /// cube's face, 1 at and beyond the locus.
        let share: Float
    }

    /// The spectral locus as the table builder sees it: each observer band in the Rec.2020
    /// working space, normalised to unit luminance and taken about the neutral axis. In that
    /// zero-luminance plane every real chromaticity lies inside the polygon the bands trace,
    /// closed by the purple line, and "how far along its own hue can this colour go and still
    /// be light" is a ray from the origin against a convex polygon.
    struct SpectralLocus: Sendable {
        /// The observer's luminous efficiency below which a band is left off the polygon. A
        /// light at the locus's ends carries almost no luminance per watt — 380 nm has a
        /// twenty-thousandth of 555 nm's — so a cell asked to hold that light at a stated
        /// luminance would hold a radiometric power no table cell can interpolate against and
        /// no half-precision copy can carry. Those tips are the least visible colours there
        /// are; a colour beyond the trimmed polygon takes the nearest light on it.
        static let luminousEfficiencyFloor: Float = 0.01

        /// Grid indices of the bands on the polygon, in wavelength order.
        let bands: [Int]
        /// Each polygon vertex: the band's unit-luminance colour less the neutral axis.
        let chroma: [SIMD3<Double>]

        static let shared = SpectralLocus()

        init() {
            bands = (0..<SpectralGrid.count).filter {
                SpectralGrid.yBar[$0] >= Self.luminousEfficiencyFloor
            }
            chroma = bands.map { band in
                let rgb = SpectralGrid.linearRec2020(fromXYZ: SIMD3(
                    SpectralGrid.xBar[band], SpectralGrid.yBar[band],
                    SpectralGrid.zBar[band]))
                return SIMD3<Double>(rgb) / Double(SpectralGrid.yBar[band])
                    - SIMD3(repeating: 1)
            }
        }

        /// Where the ray from the neutral axis along `direction` — a colour's chroma at unit
        /// luminance — leaves the locus: the multiple of `direction` at the boundary, the two
        /// grid bands bracketing the crossing, and the upper band's share of the crossing's
        /// luminance.
        func boundary(along direction: SIMD3<Double>)
            -> (reach: Double, lowerBand: Int, upperBand: Int, upperShare: Double)? {
            var best: (reach: Double, lowerBand: Int, upperBand: Int, upperShare: Double)?
            let count = chroma.count
            for lower in 0..<count {
                let upper = (lower + 1) % count
                let from = chroma[lower]
                let edge = chroma[upper] - from
                // alpha * direction - beta * edge = from, solved in the plane's x and y: the
                // zero-luminance plane is not parallel to z, so those two coordinates fix it.
                let determinant = -direction.x * edge.y + edge.x * direction.y
                guard abs(determinant) > 1e-18 else { continue }
                let alpha = (-from.x * edge.y + edge.x * from.y) / determinant
                let beta = (direction.x * from.y - direction.y * from.x) / determinant
                guard alpha > 0, beta >= -1e-9, beta <= 1 + 1e-9 else { continue }
                if best == nil || alpha < best!.reach {
                    best = (alpha, bands[lower], bands[upper], min(max(beta, 0), 1))
                }
            }
            return best
        }
    }

    /// How far past the Rec.2020 face the reflectance model is continued by projection before
    /// the monochromatic mixture begins, as the binding channel's depth below zero relative to
    /// the colour's peak: a cell and a half of the table. The mixture is far steeper than the
    /// reflectance model — monochromatic light moves the layers further per unit of chromaticity
    /// than any reflectance can — and a table cell whose corners straddle that seam
    /// interpolates it into the in-gamut colours next to it: a saturated blue read 5% wrong
    /// and a yellow's hue rotated 7° before the margin. With it, no in-gamut colour shares a
    /// cell with the mixture, and what the margin gives up is a sliver of purity no wider than
    /// the table can resolve anyway.
    static var projectionMargin: Float { 1.5 / Float(lutDimension - 1) }

    /// Reads a Rec.2020 colour as the light a table cell stands for.
    static func sceneLight(_ rgb: SIMD3<Float>) -> SceneLight {
        let peak = max(rgb.x, rgb.y, rgb.z)
        let binding = min(rgb.x, rgb.y, rgb.z)
        // A cell on a face of the Rec.2020 cube reaches it through the seam with rounding
        // noise; that is the reflectance model's own colour, not a light beyond it.
        guard binding < -1e-6 * max(peak, 1) else {
            return .reflectance(SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0)))
        }
        let weights = ColorScience.luminanceWeights
        let luminance = weights.0 * rgb.x + weights.1 * rgb.y + weights.2 * rgb.z
        guard luminance > 0 else { return .none }
        var cube: Float = 1
        var bindingChannel = 0
        var peakChannel = 0
        for channel in 0..<3 {
            if rgb[channel] < 0 {
                let reach = luminance / (luminance - rgb[channel])
                if reach < cube { cube = reach; bindingChannel = channel }
            }
            if rgb[channel] > rgb[peakChannel] { peakChannel = channel }
        }
        let neutral = SIMD3(repeating: luminance)
        var face = neutral + cube * (rgb - neutral)
        face = SIMD3(max(face.x, 0), max(face.y, 0), max(face.z, 0))
        func mirrored(_ point: SIMD3<Float>) -> SIMD3<Float> {
            let mirror = face * 2 - point
            return SIMD3(max(mirror.x, 0), max(mirror.y, 0), max(mirror.z, 0))
        }
        // Within the margin the reflectance model continues by its own slope.
        let margin = projectionMargin
        guard binding < -margin * peak else {
            return .extrapolated(face: face, mirror: mirrored(rgb))
        }
        let direction = SIMD3<Double>(rgb) / Double(luminance) - SIMD3(repeating: 1)
        guard let hit = SpectralLocus.shared.boundary(along: direction) else {
            return .extrapolated(face: face, mirror: mirrored(rgb))
        }
        // Along the colour's own ray from the neutral axis, the colour sits at 1, the cube's
        // face at `cube`, the margin at `start` — where the binding channel first reaches the
        // margin's depth below zero — and the locus at `reach`. The mixture that lands on the
        // colour is linear in that parameter, zero at the margin so it meets the continued
        // reflectance model without a step, and clamps to 1 past the locus: the cell holds
        // the locus light.
        let depth = luminance - rgb[bindingChannel]
        let rise = rgb[peakChannel] - luminance
        let start = luminance * (1 + margin) / (depth - margin * rise)
        let marginPoint = neutral + start * (rgb - neutral)
        let reach = Float(hit.reach)
        let share: Float = reach - start > 1e-6
            ? min(max((1 - start) / (reach - start), 0), 1) : 1
        return .locus(LocusLight(face: face, mirror: mirrored(marginPoint),
                                 luminance: luminance,
                                 lowerBand: hit.lowerBand, upperBand: hit.upperBand,
                                 upperShare: Float(hit.upperShare), share: share))
    }

    /// Per-row exposure of the monochromatic half of a locus light, in the same units as
    /// `spectralExposure`: the light is scaled so that its luminance is what a white
    /// reflectance of the colour's luminance would reflect under the scene illuminant, then
    /// integrated against each sensitivity row through the filter and calibrated against the
    /// stock's reference light exactly as a reflectance is.
    static func monochromaticExposure(_ light: LocusLight, sensitivities: [[Float]],
                                      illuminant: [Float], referenceIlluminant: [Float],
                                      filter: SpectralFilter?) -> [Float] {
        let anchor = max(illuminant[Illuminant.anchorIndex], 1e-12)
        let referenceAnchor = max(referenceIlluminant[Illuminant.anchorIndex], 1e-12)
        var white: Float = 0
        for i in 0..<SpectralGrid.count {
            white += illuminant[i] / anchor * SpectralGrid.yBar[i]
        }
        let target = light.luminance * white
        let lower = light.lowerBand
        let upper = light.upperBand
        let lowerPower = (1 - light.upperShare) * target
            / max(SpectralGrid.yBar[lower], 1e-12)
        let upperPower = light.upperShare * target / max(SpectralGrid.yBar[upper], 1e-12)
        let lowerThrough = lowerPower * (filter?.transmittance[lower] ?? 1)
        let upperThrough = upperPower * (filter?.transmittance[upper] ?? 1)
        let gain = filter?.gain ?? 1
        return sensitivities.map { sensitivity in
            let exposure = lowerThrough * sensitivity[lower] + upperThrough * sensitivity[upper]
            var reference: Float = 0
            for i in 0..<SpectralGrid.count {
                reference += referenceIlluminant[i] / referenceAnchor * sensitivity[i]
            }
            return gain * exposure / max(reference, 1e-12)
        }
    }

    /// Film-layer exposure for one cell of the exposure table, `point` in the table's basis.
    static func domainExposure(_ point: SIMD3<Float>, stock: FilmStock,
                               illuminant: [Float],
                               referenceIlluminant: [Float]? = nil,
                               filter: SpectralFilter? = nil) -> SIMD3<Float> {
        let rgb = ColorScience.linearExposureDomainToRec2020(point)
        func reflectance(_ colour: SIMD3<Float>) -> SIMD3<Float> {
            anchoredExposure(colour, stock: stock, illuminant: illuminant,
                             referenceIlluminant: referenceIlluminant, filter: filter)
        }
        switch sceneLight(rgb) {
        case .none:
            return .zero
        case .reflectance(let colour):
            return reflectance(colour)
        case .extrapolated(let face, let mirror):
            return extrapolatedExposure(face: reflectance(face), mirror: reflectance(mirror))
        case .locus(let light):
            let edge = extrapolatedExposure(face: reflectance(light.face),
                                            mirror: reflectance(light.mirror))
            let mono = monochromaticExposure(
                light, sensitivities: Array(stock.spectralProfile.layerSensitivity.prefix(3)),
                illuminant: illuminant,
                referenceIlluminant: referenceIlluminant ?? filmReferenceIlluminant(for: stock),
                filter: filter)
            return (1 - light.share) * edge
                + light.share * SIMD3(mono[0], mono[1], mono[2])
        }
    }

    /// The donor record's exposure for one cell of the table: the same reading of the cell.
    static func domainDonorExposure(_ point: SIMD3<Float>, donor: DonorCaptureLayer,
                                    illuminant: [Float], referenceIlluminant: [Float],
                                    filter: SpectralFilter? = nil) -> Float {
        let rgb = ColorScience.linearExposureDomainToRec2020(point)
        func reflectance(_ colour: SIMD3<Float>) -> Float {
            donorAnchoredExposure(colour, donor: donor, illuminant: illuminant,
                                  referenceIlluminant: referenceIlluminant, filter: filter)
        }
        switch sceneLight(rgb) {
        case .none:
            return 0
        case .reflectance(let colour):
            return reflectance(colour)
        case .extrapolated(let face, let mirror):
            return extrapolatedExposure(face: reflectance(face), mirror: reflectance(mirror))
        case .locus(let light):
            let edge = extrapolatedExposure(face: reflectance(light.face),
                                            mirror: reflectance(light.mirror))
            let mono = monochromaticExposure(
                light, sensitivities: [donor.sensitivity], illuminant: illuminant,
                referenceIlluminant: referenceIlluminant, filter: filter)[0]
            return (1 - light.share) * edge + light.share * mono
        }
    }

    /// The exposure table for a stock under a scene light, over the locus-enclosing domain.
    static func exposureTable(for stock: FilmStock, illuminant: [Float],
                              referenceIlluminant: [Float]? = nil,
                              filter: SpectralFilter? = nil) -> SpectralLUT {
        buildLUT({ point in
            domainExposure(point, stock: stock, illuminant: illuminant,
                           referenceIlluminant: referenceIlluminant, filter: filter)
        }, fourth: donorChannel(for: stock, illuminant: illuminant,
                                referenceIlluminant: referenceIlluminant, filter: filter))
    }

    /// The donor record's exposure for a scene colour: the same anchored reconstruction and
    /// the same stock-native calibration as the dye-forming layers.
    static func donorAnchoredExposure(_ rgb: SIMD3<Float>, donor: DonorCaptureLayer,
                                      illuminant: [Float] = SpectralGrid.d65,
                                      referenceIlluminant suppliedReference: [Float],
                                      filter: SpectralFilter? = nil) -> Float {
        let peak = max(rgb.x, rgb.y, rgb.z)
        guard peak > 0 else { return 0 }
        let radiance = peak / reconstructionAnchor
        guard let model = MeasuredReflectanceTable.shared else {
            // The compact fallback has no spectrum to weigh a fourth record with. The engine
            // gates the donor stage on the reconstruction model being loaded, so this value
            // is never read; 0 keeps the table well-formed.
            return 0
        }
        let reflectance = model.reflectance(rgb / radiance)
        var exposure: Float = 0
        var referenceExposure: Float = 0
        let anchor = max(illuminant[Illuminant.anchorIndex], 1e-12)
        let referenceAnchor = max(suppliedReference[Illuminant.anchorIndex], 1e-12)
        for i in 0..<SpectralGrid.count {
            let light = illuminant[i] / anchor
            let through = filter.map { reflectance[i] * $0.transmittance[i] } ?? reflectance[i]
            exposure += through * light * donor.sensitivity[i]
            referenceExposure += suppliedReference[i] / referenceAnchor * donor.sensitivity[i]
        }
        return (filter?.gain ?? 1) * exposure / max(referenceExposure, 1e-12) * radiance
    }

    /// Whether the wavelength-domain reconstruction is loaded — the condition the donor
    /// stage, and the exposure cube's fourth channel, are gated on together.
    static var hasReconstructionModel: Bool { MeasuredReflectanceTable.shared != nil }

    /// Number of measured spectra fitted into the bundled recovery prior.
    static var reconstructionSourceCount: Int? { MeasuredReflectanceTable.shared?.sourceCount }

    /// The exposure cube's fourth channel: the donor record's exposure on the same
    /// evaluation as the three dye-forming ones. nil — the constant 1 the slot always held —
    /// when the stock coats no donor, or when there is no reconstruction model to integrate
    /// one with (the same condition the engine gates the donor stage on).
    static func donorChannel(for stock: FilmStock,
                             illuminant: [Float] = SpectralGrid.d65,
                             referenceIlluminant suppliedReference: [Float]? = nil,
                             filter: SpectralFilter? = nil)
        -> ((SIMD3<Float>) -> Float)? {
        guard let donor = stock.donorLayers.first,
              MeasuredReflectanceTable.shared != nil else { return nil }
        let reference = suppliedReference ?? filmReferenceIlluminant(for: stock)
        return { point in
            domainDonorExposure(point, donor: donor,
                                illuminant: illuminant,
                                referenceIlluminant: reference, filter: filter)
        }
    }

    /// What the donor layers add to a table identity: nothing at all — the zero the fold
    /// starts from — for the empty array every existing stock has, so every identity that
    /// existed before donors is exactly the identity it was.
    static func donorSignature(for stock: FilmStock) -> UInt64 {
        var h: UInt64 = 0
        for donor in stock.donorLayers {
            h = (h ^ 0x444F4E4F52) &* 0x100000001b3  // "DONOR"
            for v in donor.sensitivity { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
            for v in [donor.curve.dMin, donor.curve.gamma, donor.curve.toe,
                      donor.curve.toeWidth, donor.curve.shoulder,
                      donor.curve.shoulderWidth] {
                h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3
            }
            if let secondary = donor.curve.secondary {
                h = (h ^ 1) &* 0x100000001b3
                for v in [secondary.gamma, secondary.toe, secondary.toeWidth,
                          secondary.shoulder, secondary.shoulderWidth] {
                    h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3
                }
            } else {
                h = h &* 0x100000001b3
            }
            for v in donor.inhibition { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        }
        return h
    }

    /// Internal rather than private so the negative-viewing table can be checked against the model
    /// it claims to be a mirror of.
    /// `density` is one entry per *developed record* and `dyes` one spectrum per *dye*, and
    /// the sum below pairs them off by index — which is the single line that makes capture
    /// layer *i* mean dye *i*. For every stock shipped so far the two counts are both three
    /// and the pairing is the identity, so nothing here is wrong; it is the assumption a
    /// fourth capture layer would have to break, by putting an N-by-dye forming matrix in
    /// front of this sum rather than indexing straight through.
    static func transmissionRGB(density: [Float], dyes: [[Float]],
                                flare: Float = 0,
                                neutralDensity: Float = 0,
                                illuminant: [Float]? = nil) -> SIMD3<Float> {
        assert(density.count == dyes.count,
               "density must be dye-aligned: \(density.count) records, \(dyes.count) dyes")
        var spectrum = [Float](repeating: 0, count: SpectralGrid.count)
        let scale = 1 / (1 + flare)
        for i in 0..<SpectralGrid.count {
            var d = neutralDensity
            for dye in 0..<dyes.count { d += density[dye] * dyes[dye][i] }
            spectrum[i] = (pow(10, -d) + flare) * scale
        }
        guard let illuminant else {
            return SpectralGrid.toLinearDisplayP3(reflectance: spectrum)
        }
        return SpectralGrid.toLinearDisplayP3(reflectance: spectrum,
                                              under: illuminant)
    }

    // Internal so the crossover tests can mirror the print exposure path.
    static func paperExposure(density: [Float], dyes: [[Float]],
                                      lamp: [Float], paperSensitivity: [[Float]],
                                      neutralDensity: Float = 0) -> SIMD3<Float> {
        var e = SIMD3<Float>(repeating: 0)
        for i in 0..<SpectralGrid.count {
            let d = density[0] * dyes[0][i] + density[1] * dyes[1][i]
                  + density[2] * dyes[2][i] + neutralDensity
            let transmitted = lamp[i] * pow(10, -d)
            e.x += transmitted * paperSensitivity[0][i]
            e.y += transmitted * paperSensitivity[1][i]
            e.z += transmitted * paperSensitivity[2][i]
        }
        return e
    }

    /// The per-channel log-exposure cast a reference-anchored medium leaves in
    /// this stock's positive: the stock's own mid-grey red/blue-over-green
    /// read minus the reference's. Zero for the reference itself, for every
    /// medium that times per stock, and for monochrome — one exposure, output
    /// forced neutral, so a colour offset would be unreachable paint. The reference and the
    /// ceiling default to the medium's committed profile; a test hands in its own.
    static func referenceCastOffset(midEnergy: SIMD3<Float>, stock: FilmStock,
                                    paper: PrintPaper,
                                    reference: SIMD2<Float> = PrintPaper.labScanReferenceMidRatio,
                                    ceiling: Float = PrintPaper.labScanCastCeiling)
        -> SIMD3<Float> {
        guard paper.isReferenceAnchored, !stock.isMonochrome else { return .zero }
        var red = log10(max(midEnergy.x, 1e-12) / max(midEnergy.y, 1e-12))
            - reference.x
        var blue = log10(max(midEnergy.z, 1e-12) / max(midEnergy.y, 1e-12))
            - reference.y
        // The profile's correction authority: the machine's per-frame colour
        // pass hands small casts through as film character and pulls anything
        // larger back to this ceiling, direction kept. Calibrated against the
        // same-lab corpus (`labScanCastCeiling`); without it a stock far from
        // the reference — a Fuji mid-scale, a remjet-free cine negative —
        // scans 2-9x warmer than the lab ever lets it.
        let magnitude = (red * red + blue * blue).squareRoot()
        if magnitude > ceiling {
            let held = ceiling / magnitude
            red *= held
            blue *= held
        }
        return SIMD3(red, 0, blue)
    }

    /// The numbers `PrintPaper.labScanReferenceMidRatio` and
    /// `labScanReferenceBalance` are committed from: the given stock's
    /// mid-grey read through the lab scan's bands, and its solved balance on
    /// that medium. Public so `fotufilm --dump-labscan-reference` can print
    /// them for re-committing; the render path reads only the constants.
    public static func labScanReferenceSolve(for stock: FilmStock)
        -> (midRatioRed: Float, midRatioBlue: Float, balance: [Float]) {
        let paper = PrintPaper.labScan
        let midDensity = (0..<3).map { stock.curves[$0].density(logExposure: 0) }
        let midEnergy = paperExposure(density: midDensity,
                                      dyes: stock.spectralProfile.imageDyeDensity,
                                      lamp: SpectralGrid.equalEnergy,
                                      paperSensitivity: paper.sensitivity)
        return (log10(max(midEnergy.x, 1e-12) / max(midEnergy.y, 1e-12)),
                log10(max(midEnergy.z, 1e-12) / max(midEnergy.y, 1e-12)),
                neutralPrintingBalance(for: stock, paper: paper))
    }
}

extension SpectralRuntime {
    /// The per-channel scaling of print exposure that carries a stock's
    /// neutral wedge onto one printed scale, on this medium.
    static func neutralPrintingBalance(for stock: FilmStock,
                                       paper: PrintPaper) -> [Float] {
        guard !stock.isReversal, !stock.isMonochrome,
              paper.acceptsPrintCorrection else { return [1, 1, 1] }

        let key = cacheIdentifier(for: stock, paper: paper)
        balanceLock.lock()
        if let found = balanceCache.value(for: key) {
            balanceLock.unlock()
            return found
        }
        balanceLock.unlock()

        let perStop = Float(log10(2.0))
        let paperSensitivity = paper.sensitivity
        let lamp = paper.isScan ? SpectralGrid.equalEnergy
                                : SpectralGrid.enlarger3200K
        let dyes = stock.spectralProfile.imageDyeDensity
        let midDensity = (0..<3).map { stock.curves[$0].density(logExposure: 0) }
        let midEnergy = paperExposure(density: midDensity, dyes: dyes,
                                      lamp: lamp, paperSensitivity: paperSensitivity)
        let curves = paper.printCurves(for: stock)
        let xMids = curves.map { record in
            record.logExposure(
                density: record.dMin + paper.anchorDensity(stock.paperMidDensity))
        }

        let relatives: [SIMD3<Float>] = stride(from: Float(-5), through: 5, by: 0.25)
            .map { stops in
                let density = (0..<3).map {
                    stock.developedDensity(layer: $0, logExposure: stops * perStop)
                }
                let energy = paperExposure(density: density, dyes: dyes,
                                           lamp: lamp, paperSensitivity: paperSensitivity)
                return SIMD3<Float>(
                    log10(max(energy.x, 1e-12) / max(midEnergy.x, 1e-12)),
                    log10(max(energy.y, 1e-12) / max(midEnergy.y, 1e-12)),
                    log10(max(energy.z, 1e-12) / max(midEnergy.z, 1e-12)))
            }

        let paperDyes = paper.dyes
        let flare = paper.viewingFlare
        let viewingLight = referenceViewingLight(for: paper)

        /// One wedge point as the viewer has it: three printed densities,
        /// each developed along its own record, then read through the paper's
        /// own dyes.
        func viewed(_ relative: SIMD3<Float>, _ scale: [Float]) -> SIMD3<Float> {
            let printed = (0..<3).map { channel in
                curves[channel].density(
                    logExposure: xMids[channel]
                        + scale[channel] * relative[channel])
                    - curves[channel].dMin
            }
            return transmissionRGB(density: printed, dyes: paperDyes, flare: flare,
                                   illuminant: viewingLight)
        }

        /// How far the printed wedge departs from grey, in the log domain the
        /// densities live in, summed over the wedge.
        func cost(_ scale: [Float]) -> Float {
            var total: Float = 0
            for relative in relatives {
                let rgb = viewed(relative, scale)
                let g = log10(max(rgb.y, 1e-6))
                let dr = log10(max(rgb.x, 1e-6)) - g
                let db = log10(max(rgb.z, 1e-6)) - g
                total += dr * dr + db * db
            }
            return total
        }

        var solved: [Float] = [1, 1, 1]
        /// Minimise along one channel with the others held, by a coarse sweep
        /// and a golden-section refine.
        func minimise(channel: Int, around centre: Float, span: Float) {
            var trial = solved
            func at(_ scale: Float) -> Float {
                trial[channel] = scale
                return cost(trial)
            }
            var bestScale = centre
            var bestCost = Float.greatestFiniteMagnitude
            for step in stride(from: max(centre - span, 0.2), through: centre + span,
                               by: 0.01) {
                let c = at(step)
                if c < bestCost { bestCost = c; bestScale = step }
            }
            var low = max(bestScale - 0.01, 0.2)
            var high = bestScale + 0.01
            let phi: Float = 0.6180339887
            var c1 = high - phi * (high - low)
            var c2 = low + phi * (high - low)
            var f1 = at(c1)
            var f2 = at(c2)
            for _ in 0..<48 {
                if f1 < f2 {
                    high = c2; c2 = c1; f2 = f1
                    c1 = high - phi * (high - low)
                    f1 = at(c1)
                } else {
                    low = c1; c1 = c2; f1 = f2
                    c2 = low + phi * (high - low)
                    f2 = at(c2)
                }
            }
            solved[channel] = (low + high) / 2
        }

        minimise(channel: 0, around: 1, span: 0.6)
        minimise(channel: 2, around: 1, span: 0.6)
        for _ in 0..<2 {
            minimise(channel: 0, around: solved[0], span: 0.1)
            minimise(channel: 2, around: solved[2], span: 0.1)
        }

        balanceLock.lock()
        balanceCache.insert(solved, for: key)
        balanceLock.unlock()
        return solved
    }

    /// Display-linear luminance of the finished print (or viewed transparency) for a neutral patch
    /// at each of `stops` from metered mid-grey — the system's neutral tone scale, computed by
    /// mirroring the pipeline's own output model rather than by fitting one.
    static func neutralToneScale(stops: [Float], stock: FilmStock,
                                 paper: PrintPaper = .default,
                                 printCorrection: Float) -> [Float] {
        // Display-linear print RGB is Display P3, so its luminance uses the P3 weights.
        let luma = ColorScience.displayP3LuminanceWeights
        func luminance(_ rgb: SIMD3<Float>) -> Float {
            luma.0 * rgb.x + luma.1 * rgb.y + luma.2 * rgb.z
        }
        let perStop = Float(log10(2.0))

        if stock.isReversal {
            let basis = neutralDensityBasis(for: stock)
            func aligned(_ density: [Float]) -> [Float] { basis(density) }
            let balance = reversalBalance(for: stock, aligned: aligned)
            return stops.map { s in
                let density = aligned((0..<3).map {
                    stock.developedDensity(layer: $0, logExposure: s * perStop)
                })
                let rgb = transmissionRGB(
                    density: density,
                    dyes: stock.spectralProfile.imageDyeDensity) * balance
                return luminance(SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0)))
            }
        }

        if paper.isNegative {
            let dyes = stock.spectralProfile.imageDyeDensity
            return stops.map { s in
                let density = (0..<3).map {
                    stock.developedDensity(layer: $0, logExposure: s * perStop)
                }
                let rgb = transmissionRGB(density: density, dyes: dyes)
                return luminance(SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0)))
            }
        }

        let paperSensitivity = paper.sensitivity
        let lamp = paper.isScan ? SpectralGrid.equalEnergy
                                : SpectralGrid.enlarger3200K
        let midDensity = (0..<3).map { stock.curves[$0].density(logExposure: 0) }
        let midEnergy = paperExposure(density: midDensity,
                                      dyes: stock.spectralProfile.imageDyeDensity,
                                      lamp: lamp, paperSensitivity: paperSensitivity)
        let neutralMid = neutralDensity(stock, 0)
        let curves = paper.printCurves(for: stock)
        let xMids = curves.map { record in
            record.logExposure(
                density: record.dMin + paper.anchorDensity(stock.paperMidDensity))
        }
        let masking = stock.printingContrastScale(correction: printCorrection,
                                                  paper: paper)
        let viewingLight = referenceViewingLight(for: paper)
        return stops.map { s in
            let density = (0..<3).map {
                stock.developedDensity(layer: $0, logExposure: s * perStop)
            }
            let relative: SIMD3<Float>
            if paper.readsLayersDirectly {
                relative = SIMD3((0..<3).map { layer -> Float in
                    let exposure = stock.curves[layer].logExposure(density: density[layer])
                    return neutralMid - neutralDensity(stock, exposure)
                })
            } else {
                let energy = paperExposure(density: density,
                                           dyes: stock.spectralProfile.imageDyeDensity,
                                           lamp: lamp, paperSensitivity: paperSensitivity)
                // The same reference cast the printing LUT carries — this
                // mirror walks a neutral wedge, and on a profiled medium a
                // neutral wedge does not print neutral.
                relative = SIMD3<Float>(
                    log10(max(energy.x, 1e-12) / max(midEnergy.x, 1e-12)),
                    log10(max(energy.y, 1e-12) / max(midEnergy.y, 1e-12)),
                    log10(max(energy.z, 1e-12) / max(midEnergy.z, 1e-12)))
                    + referenceCastOffset(midEnergy: midEnergy, stock: stock,
                                          paper: paper)
            }
            let printed = (0..<3).map { channel in
                curves[channel].density(
                    logExposure: xMids[channel] + masking[channel]
                        * relative[channel]) - curves[channel].dMin
            }
            let rgb: SIMD3<Float>
            if paper.isScan {
                // A scan's characterization holds the receiver's luminance exactly, so this
                // neutral mirror needs only the receiver. The 709 delivery is likewise a
                // luminance-preserving change of primaries.
                rgb = SIMD3(pow(10, -printed[0]), pow(10, -printed[1]),
                            pow(10, -printed[2]))
            } else {
                rgb = transmissionRGB(density: printed, dyes: paper.dyes,
                                      flare: paper.viewingFlare,
                                      illuminant: viewingLight)
            }
            return luminance(SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0)))
        }
    }
}

// MARK: - Scene-light film exposure

/// The film-side half of the physical-light system: the same scene temperature that already
/// steers the camera-profile delta also decides what light the emulsion integrates. The
/// expensive object is the per-stock 33³ exposure LUT, so exact SPDs are cached at that level.
extension SpectralRuntime {
    /// Validates a stated CCT without quantizing or suppressing daylight temperatures.
    public static func sceneLightKelvin(_ cct: Float?) -> Float? {
        guard let cct, cct.isFinite, cct > 0 else { return nil }
        return cct
    }

    /// Weight of the warm (illuminant A) anchor at `cct` — the DNG dual-illuminant rule,
    /// identical to `DualIlluminantMatrices.matrix(cct:)`: linear in mired between the 2856 K
    /// and 6504 K anchors, clamped so temperatures beyond an anchor hold that anchor.
    static func sceneLightWarmWeight(cct: Float) -> Float {
        let coolMired = 1 / DualIlluminantMatrices.daylightKelvin
        let warmMired = 1 / DualIlluminantMatrices.tungstenKelvin
        let mired = 1 / max(cct, 1)
        return clamp((mired - coolMired) / (warmMired - coolMired), 0, 1)
    }

    private static let sceneLightLock = NSLock()
    nonisolated(unsafe) private static var sceneAnchorCache =
        BoundedCache<UInt64, (warm: SpectralLUT, cool: SpectralLUT)>(limit: 16)
    nonisolated(unsafe) private static var sceneBlendCache =
        BoundedCache<UInt64, SpectralLUT>(limit: 32)

    private static func illuminantSignature(_ illuminant: [Float]) -> UInt64 {
        precondition(illuminant.count == SpectralGrid.count)
        var h: UInt64 = 0xcbf29ce484222325
        for value in illuminant {
            precondition(value.isFinite && value >= 0, "illuminant SPD must be finite and nonnegative")
            h = (h ^ UInt64(value.bitPattern)) &* 0x100000001b3
        }
        precondition(illuminant.contains { $0 > 0 }, "illuminant SPD must contain energy")
        return h
    }

    /// What the exposure table actually depends on: the spectral profile, plus the RGB
    /// sensitivity matrix the no-reconstruction fallback reads.
    private static func sceneLightKey(for stock: FilmStock) -> UInt64 {
        var h = stock.spectralProfile.signature
        h = (h ^ UInt64(stock.referenceIlluminantKelvin.bitPattern)) &* 0x100000001b3
        for row in stock.sensitivity {
            for v in row { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        }
        let donor = donorSignature(for: stock)
        if donor != 0 { h = (h ^ donor) &* 0x100000001b3 }
        return h
    }

    /// The two common anchor exposure tables for a stock. They are explicit scene lights; the
    /// ordinary table without capture metadata uses the stock's native reference instead.
    static func sceneLightAnchors(for stock: FilmStock)
        -> (warm: SpectralLUT, cool: SpectralLUT) {
        let key = sceneLightKey(for: stock)
        sceneLightLock.lock()
        defer { sceneLightLock.unlock() }
        if let found = sceneAnchorCache.value(for: key) { return found }
        let built = (
            warm: exposureTable(for: stock, illuminant: Illuminant.a),
            cool: exposureTable(for: stock, illuminant: SpectralGrid.d65)
        )
        sceneAnchorCache.insert(built, for: key)
        return built
    }

    /// The exposure-domain table under the exact CIE-locus SPD for the stated CCT. Direct sampling
    /// requires coordinates returned by `ColorScience.linearRec2020ToExposureDomain`.
    public static func sceneExposure(for stock: FilmStock, cct: Float) -> SpectralLUT {
        sceneExposure(for: stock, illuminant: Illuminant.atLocus(kelvin: cct))
    }

    /// The exposure-domain table under a caller-supplied SPD on `SpectralGrid`. Direct sampling
    /// requires coordinates returned by `ColorScience.linearRec2020ToExposureDomain`.
    public static func sceneExposure(for stock: FilmStock,
                                     illuminant: [Float]) -> SpectralLUT {
        let key = (sceneLightKey(for: stock) ^ illuminantSignature(illuminant))
            &* 0x100000001b3
        sceneLightLock.lock()
        if let found = sceneBlendCache.value(for: key) {
            sceneLightLock.unlock()
            return found
        }
        sceneLightLock.unlock()
        let built = exposureTable(for: stock, illuminant: illuminant)
        sceneLightLock.lock()
        sceneBlendCache.insert(built, for: key)
        sceneLightLock.unlock()
        return built
    }

    /// Says what light the film integrated, on the same switch as the rest of the
    /// FOTUFILM_ diagnostics: set FOTUFILM_PROFILE_TRACE to see one line per table selection.
    static func traceSceneLight(stock: FilmStock, cct: Float) {
        guard ProcessInfo.processInfo.environment["FOTUFILM_PROFILE_TRACE"] != nil else {
            return
        }
        print(String(format: "film exposure: %@ at %.0f K", stock.name, cct))
    }
}

// MARK: - Film exposure through a lens filter

/// The filter's half of the exposure table. A filter sits in the beam ahead of everything, so
/// the only thing in the engine it can touch is what light the emulsion integrated — develop and
/// print happen in the dark. That makes it exactly the same kind of change the scene's own colour
/// temperature is, and it is built the same way: two anchor tables blended in mired, cached per
/// stack, nothing recomputed per pixel or per frame.
extension SpectralRuntime {

    /// The scene's light as an exact CIE-locus spectrum. Used for the metering scale, which has to
    /// be worked out under the light the meter was pointed at — a filter's factor is not the
    /// same number in tungsten as in daylight, and that is a real difference, not a rounding.
    static func sceneIlluminant(cct: Float?) -> [Float] {
        guard let cct else { return SpectralGrid.d65 }
        return Illuminant.atLocus(kelvin: cct)
    }

    /// The filter as the integration wants it, resolved against the stock and the light: the
    /// transmittance, the metering scale, and the per-layer ratio the compact fallback needs.
    static func spectralFilter(for stock: FilmStock, stack: LensFilterStack,
                               illuminant: [Float]) -> SpectralFilter {
        SpectralFilter(
            transmittance: stack.transmittance,
            gain: stack.exposureGain(stock: stock, illuminant: illuminant),
            layerRatio: stack.layerTransmittances(stock: stock, illuminant: illuminant))
    }

    private static let filterLock = NSLock()
    nonisolated(unsafe) private static var filteredAnchorCache =
        BoundedCache<UInt64, (warm: SpectralLUT, cool: SpectralLUT)>(limit: 16)
    nonisolated(unsafe) private static var filteredExposureCache =
        BoundedCache<UInt64, SpectralLUT>(limit: 32)

    /// The two anchor exposure tables for a stock behind a filter, built with the metering scale
    /// left out so that one pair serves every colour temperature. Each anchor carries the
    /// filter's transmittance under its own light, which is the part that cannot be factored
    /// out: the filter and the sensitivities are integrated against each other band by band.
    static func filteredAnchors(for stock: FilmStock, stack: LensFilterStack)
        -> (warm: SpectralLUT, cool: SpectralLUT) {
        let key = (filterKey(for: stock) ^ stack.signature) &* 0x100000001b3
        filterLock.lock()
        defer { filterLock.unlock() }
        if let found = filteredAnchorCache.value(for: key) { return found }
        func anchor(_ illuminant: [Float]) -> SpectralLUT {
            var filter = spectralFilter(for: stock, stack: stack, illuminant: illuminant)
            filter.gain = 1
            return exposureTable(for: stock, illuminant: illuminant, filter: filter)
        }
        let built = (warm: anchor(Illuminant.a), cool: anchor(SpectralGrid.d65))
        filteredAnchorCache.insert(built, for: key)
        return built
    }

    /// The exposure-domain table behind this stack. nil uses the stock's native reference. Direct
    /// sampling requires coordinates returned by `ColorScience.linearRec2020ToExposureDomain`.
    public static func filteredExposure(for stock: FilmStock,
                                        illuminant supplied: [Float]?,
                                        stack: LensFilterStack) -> SpectralLUT {
        precondition(!stack.isEmpty, "an empty stack has no table of its own to build")
        let illuminant = supplied ?? filmReferenceIlluminant(for: stock)
        let gain = stack.exposureGain(stock: stock, illuminant: illuminant)
        let illuminantID = illuminantSignature(illuminant)

        var key = (filterKey(for: stock) ^ stack.signature) &* 0x100000001b3
        key = (key ^ illuminantID) &* 0x100000001b3
        key = (key ^ UInt64(gain.bitPattern)) &* 0x100000001b3
        filterLock.lock()
        if let found = filteredExposureCache.value(for: key) {
            filterLock.unlock()
            return found
        }
        filterLock.unlock()

        var filter = spectralFilter(for: stock, stack: stack, illuminant: illuminant)
        filter.gain = gain
        let table = exposureTable(for: stock, illuminant: illuminant, filter: filter)

        filterLock.lock()
        filteredExposureCache.insert(table, for: key)
        filterLock.unlock()
        return table
    }

    /// CCT convenience for existing clients; the exact CIE-locus SPD is used.
    public static func filteredExposure(for stock: FilmStock, cct: Float?,
                                        stack: LensFilterStack) -> SpectralLUT {
        filteredExposure(for: stock,
                         illuminant: cct.map(Illuminant.atLocus(kelvin:)),
                         stack: stack)
    }

    /// What a filtered exposure table depends on, on the stock's side: the same identity the
    /// unfiltered scene-light tables key on.
    private static func filterKey(for stock: FilmStock) -> UInt64 {
        var h = stock.spectralProfile.signature
        h = (h ^ UInt64(stock.referenceIlluminantKelvin.bitPattern)) &* 0x100000001b3
        for row in stock.sensitivity {
            for v in row { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        }
        let donor = donorSignature(for: stock)
        if donor != 0 { h = (h ^ donor) &* 0x100000001b3 }
        return h
    }
}

public enum SpectralGrid {
    /// Spacing of the grid in nanometres. 5 nm since the 2026-09 audit: the film records'
    /// sensitising-dye cut-offs fall a decade in 20 nm, and 10 nm point samples of them moved
    /// a ColorChecker patch's layer exposure by up to 0.1 stop against the dense trace.
    public static let stepNM: Float = 5
    public static let wavelengths: [Float] = stride(from: Float(380), through: 780, by: stepNM).map { $0 }
    public static let count = 81
    static let xBar: [Float] = [
        0.001368, 0.002236, 0.004243, 0.00765, 0.01431, 0.02319, 0.04351, 0.07763,
        0.13438, 0.21477, 0.2839, 0.3285, 0.34828, 0.34806, 0.3362, 0.3187,
        0.2908, 0.2511, 0.19536, 0.1421, 0.09564, 0.05795001, 0.03201, 0.0147,
        0.0049, 0.0024, 0.0093, 0.0291, 0.06327, 0.1096, 0.1655, 0.2257499,
        0.2904, 0.3597, 0.4334499, 0.5120501, 0.5945, 0.6784, 0.7621, 0.8425,
        0.9163, 0.9786, 1.0263, 1.0567, 1.0622, 1.0456, 1.0026, 0.9384,
        0.8544499, 0.7514, 0.6424, 0.5419, 0.4479, 0.3608, 0.2835, 0.2187,
        0.1649, 0.1212, 0.0874, 0.0636, 0.04677, 0.0329, 0.0227, 0.01584,
        0.01135916, 0.008110916, 0.005790346, 0.004109457, 0.002899327, 0.00204919, 0.001439971, 0.000999949,
        0.000690079, 0.000476021, 0.000332301, 0.000234826, 0.000166151, 0.000117413, 8.3075e-05, 5.8707e-05,
        4.151e-05,
    ]
    static let yBar: [Float] = [
        3.9e-05, 6.4e-05, 0.00012, 0.000217, 0.000396, 0.00064, 0.00121, 0.00218,
        0.004, 0.0073, 0.0116, 0.01684, 0.023, 0.0298, 0.038, 0.048,
        0.06, 0.0739, 0.09098, 0.1126, 0.13902, 0.1693, 0.20802, 0.2586,
        0.323, 0.4073, 0.503, 0.6082, 0.71, 0.7932, 0.862, 0.9148501,
        0.954, 0.9803, 0.9949501, 1, 0.995, 0.9786, 0.952, 0.9154,
        0.87, 0.8163, 0.757, 0.6949, 0.631, 0.5668, 0.503, 0.4412,
        0.381, 0.321, 0.265, 0.217, 0.175, 0.1382, 0.107, 0.0816,
        0.061, 0.04458, 0.032, 0.0232, 0.017, 0.01192, 0.00821, 0.005723,
        0.004102, 0.002929, 0.002091, 0.001484, 0.001047, 0.00074, 0.00052, 0.0003611,
        0.0002492, 0.0001719, 0.00012, 8.48e-05, 6e-05, 4.24e-05, 3e-05, 2.12e-05,
        1.499e-05,
    ]
    static let zBar: [Float] = [
        0.006450001, 0.01054999, 0.02005001, 0.03621, 0.06785001, 0.1102, 0.2074, 0.3713,
        0.6456, 1.0390501, 1.3856, 1.62296, 1.74706, 1.7826, 1.77211, 1.7441,
        1.6692, 1.5281, 1.28764, 1.0419, 0.8129501, 0.6162, 0.46518, 0.3533,
        0.272, 0.2123, 0.1582, 0.1117, 0.07824999, 0.05725001, 0.04216, 0.02984,
        0.0203, 0.0134, 0.008749999, 0.005749999, 0.0039, 0.002749999, 0.0021, 0.0018,
        0.001650001, 0.0014, 0.0011, 0.001, 0.0008, 0.0006, 0.00034, 0.00024,
        0.00019, 0.0001, 5e-05, 3e-05, 2e-05, 1e-05, -0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0,
    ]
    public static let d65: [Float] = [
        49.9755, 52.3118, 54.6482, 68.7015, 82.7549, 87.1204, 91.486, 92.4589,
        93.4318, 90.057, 86.6823, 95.7736, 104.865, 110.936, 117.008, 117.41,
        117.812, 116.336, 114.861, 115.392, 115.923, 112.367, 108.811, 109.082,
        109.354, 108.578, 107.802, 106.296, 104.79, 106.239, 107.689, 106.047,
        104.405, 104.225, 104.046, 102.023, 100, 98.1671, 96.3342, 96.0611,
        95.788, 92.2368, 88.6856, 89.3459, 90.0062, 89.8026, 89.5991, 88.6489,
        87.6987, 85.4936, 83.2886, 83.4939, 83.6992, 81.863, 80.0268, 80.1207,
        80.2146, 81.2462, 82.2778, 80.281, 78.2842, 74.0027, 69.7213, 70.6652,
        71.6091, 72.979, 74.349, 67.9765, 61.604, 65.7448, 69.8856, 72.4863,
        75.087, 69.3398, 63.5927, 55.0054, 46.4182, 56.6118, 66.8054, 65.0941,
        63.3828,
    ]

    static func asymmetricGaussian(peak: Float, leftSigma: Float,
                                   rightSigma: Float) -> [Float] {
        wavelengths.map { wavelength in
            let sigma = wavelength < peak ? leftSigma : rightSigma
            let x = (wavelength - peak) / max(sigma, 1)
            return exp(-0.5 * x * x)
        }
    }

    /// Slowest rate at which a digitised record is allowed to be continued past the end of its
    /// printed trace, in log10 sensitivity per nanometre.
    static let minimumTailDecayPerNM: Float = 0.05
    /// How far below a record's peak the continuation runs before the layer is treated as blind.
    static let tailDecades: Float = 3

    /// Continues a measured sensitivity record beyond the wavelength span the publication printed.
    static func continuedTails(_ layer: [Float]) -> [Float] {
        guard let peak = layer.max(), peak > 0 else { return layer }
        let support = layer.indices.filter { layer[$0] > 0 }
        guard let low = support.first, let high = support.last, high > low else {
            return layer
        }
        let step = stepNM
        let cutoff = log10(peak) - tailDecades
        var result = layer

        /// Terminal slope in log10 per nm over up to 30 nm of trace, signed so that a positive
        /// value means the record is falling outward.
        func decay(from edge: Int, inward: Int) -> Float {
            let reach = Int((30 / stepNM).rounded())
            let anchor = inward > 0 ? min(high, edge + reach) : max(low, edge - reach)
            guard anchor != edge else { return minimumTailDecayPerNM }
            let rise = log10(layer[edge]) - log10(layer[anchor])
            let span = Float(abs(edge - anchor)) * step
            return max(-rise / span, minimumTailDecayPerNM)
        }

        if high < layer.count - 1 {
            let rate = decay(from: high, inward: -1)
            var value = log10(layer[high])
            for i in (high + 1)..<layer.count {
                value -= rate * step
                result[i] = value > cutoff ? pow(10, value) : 0
            }
        }
        if low > 0 {
            let rate = decay(from: low, inward: 1)
            var value = log10(layer[low])
            for i in stride(from: low - 1, through: 0, by: -1) {
                value -= rate * step
                result[i] = value > cutoff ? pow(10, value) : 0
            }
        }
        return result
    }

    static func normalizeSensitivities(_ layers: [[Float]]) -> [[Float]] {
        layers.map { layer in
            let integral = zip(layer, d65).reduce(Float.zero) { $0 + $1.0 * $1.1 }
            return layer.map { $0 / max(integral, 1e-12) }
        }
    }

    static func dyes(family: FilmDyeFamily) -> [[Float]] {
        if family == .monochrome {
            return [[Float](repeating: 1.0 / 3.0, count: count),
                    [Float](repeating: 1.0 / 3.0, count: count),
                    [Float](repeating: 1.0 / 3.0, count: count)]
        }
        let centers: [Float], widths: [Float], floor: Float
        switch family {
        case .kodakNegative:
            centers = [665, 548, 445]; widths = [64, 50, 45]; floor = 0.035
        case .fujiNegative:
            centers = [675, 545, 445]; widths = [58, 46, 42]; floor = 0.025
        case .motionNegative:
            centers = [670, 550, 445]; widths = [56, 45, 40]; floor = 0.018
        case .kodachrome:
            centers = [650, 535, 440]; widths = [50, 42, 38]; floor = 0.012
        case .monochrome:
            fatalError("handled above")
        }
        var result = (0..<3).map { channel in
            asymmetricGaussian(peak: centers[channel], leftSigma: widths[channel],
                               rightSigma: widths[channel]).map { $0 + floor }
        }
        for i in 0..<count {
            for layer in 0..<3 { result[layer][i] = pow(result[layer][i], 6.0) }
        }
        return partition(result)
    }

    /// Rescales three dye density spectra so equal cyan, magenta and yellow
    /// densities come out spectrally neutral.
    static func partition(_ densities: [[Float]]) -> [[Float]] {
        precondition(densities.count == 3)
        var result = densities
        for i in 0..<count {
            let sum = result[0][i] + result[1][i] + result[2][i]
            for layer in 0..<3 { result[layer][i] /= max(sum, 1e-12) }
        }
        return result
    }

    /// The receiver supplied by PrintPaperSpectra (analytic examples in this repository).
    static let paperDyes: [[Float]] = partition(
        zip(PrintPaperSpectra.dyeDensity, PrintPaperSpectra.neutralAmounts)
            .map { record, amount in record.map { $0 * amount } })
    /// Extend and normalize the configured receiver sensitivity.
    static let paperSensitivity: [[Float]] =
        normalizeSensitivities(PrintPaperSpectra.layerSensitivity.map(continuedTails))

    /// Planck's law on the grid, normalized to its own peak.
    static func blackbody(kelvinK: Float) -> [Float] {
        let c2: Float = 14_387_769
        let temperature = max(kelvinK, 1)
        var values = wavelengths.map { wavelength -> Float in
            1 / (pow(wavelength, 5) * (exp(c2 / (wavelength * temperature)) - 1))
        }
        let peak = values.max() ?? 1
        for i in values.indices { values[i] /= peak }
        return values
    }

    /// CIE 1931 tristimulus of a spectral power distribution on the grid.
    /// One value off a grid-sampled curve at an arbitrary wavelength, read between the two
    /// nearest samples and held flat outside the grid.
    static func interpolate(_ curve: [Float], atWavelength wavelength: Float) -> Float {
        guard curve.count == count else { return 0 }
        let position = (wavelength - wavelengths[0]) / stepNM
        if position <= 0 { return curve[0] }
        if position >= Float(count - 1) { return curve[count - 1] }
        let low = Int(position)
        let fraction = position - Float(low)
        return curve[low] * (1 - fraction) + curve[low + 1] * fraction
    }

    static func xyz(spectrum: [Float]) -> SIMD3<Float> {
        precondition(spectrum.count == count)
        var result = SIMD3<Float>(repeating: 0)
        for i in 0..<count {
            result.x += spectrum[i] * xBar[i]
            result.y += spectrum[i] * yBar[i]
            result.z += spectrum[i] * zBar[i]
        }
        return result
    }

    static func linearDisplayP3(fromXYZ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            2.4934969 * v.x - 0.9313836 * v.y - 0.4027108 * v.z,
           -0.8294890 * v.x + 1.7626641 * v.y + 0.0236247 * v.z,
            0.0358458 * v.x - 0.0761724 * v.y + 0.9568845 * v.z)
    }

    /// XYZ into the linear Rec.2020 working space, composed through the P3 matrix and the
    /// engine's own seam digits rather than a third independently-rounded matrix, so a colour
    /// reaching the working space by either route lands on the same floats.
    static func linearRec2020(fromXYZ v: SIMD3<Float>) -> SIMD3<Float> {
        ColorScience.linearDisplayP3ToRec2020(linearDisplayP3(fromXYZ: v))
    }

    static let enlarger3200K: [Float] = blackbody(kelvinK: 3200)

    /// The flat lamp a scan integrates under: its LED emission already lives in
    /// the sensor bands.
    static let equalEnergy = [Float](repeating: 1, count: count)

    /// Display primaries for the print side of the model. The scene side reconstructs spectra
    /// from linear Rec.2020 with the measured-reflectance prior; everything a finished print or
    /// transparency is *viewed* as integrates to Display P3, which remains the output contract.
    static func toLinearDisplayP3(reflectance: [Float]) -> SIMD3<Float> {
        toLinearDisplayP3(reflectance: reflectance, under: d65)
    }

    /// The same observer under a stated light. Bradford chromatic adaptation carries the
    /// illuminant white to the renderer's D65 white in cone-response space: a spectrally flat
    /// reflectance reads the same grey under every illuminant, while the paper dyes' spectral
    /// metamerism remains. Dividing Display P3 channels directly is not a von Kries transform;
    /// display primaries are not cone-response channels and produce hue errors away from neutral.
    static func toLinearDisplayP3(reflectance: [Float],
                                  under illuminant: [Float]) -> SIMD3<Float> {
        precondition(reflectance.count == count)
        var reflected = [Float](repeating: 0, count: count)
        for i in 0..<count { reflected[i] = illuminant[i] * reflectance[i] }
        var reflectedXYZ = xyz(spectrum: reflected)
        var whiteXYZ = xyz(spectrum: illuminant)
        reflectedXYZ /= max(whiteXYZ.y, 1e-12)
        whiteXYZ /= max(whiteXYZ.y, 1e-12)
        let sourceLMS = bradfordLMS(fromXYZ: whiteXYZ)
        let destinationLMS = bradfordLMS(fromXYZ: d65WhiteXYZ)
        let reflectedLMS = bradfordLMS(fromXYZ: reflectedXYZ)
        let adaptedLMS = SIMD3(
            reflectedLMS.x * destinationLMS.x / max(sourceLMS.x, 1e-12),
            reflectedLMS.y * destinationLMS.y / max(sourceLMS.y, 1e-12),
            reflectedLMS.z * destinationLMS.z / max(sourceLMS.z, 1e-12))
        let rgb = linearDisplayP3(fromXYZ: xyz(fromBradfordLMS: adaptedLMS))
        // The published D65 table is sampled at 10 nm while the P3 matrix carries the analytic
        // D65 white. This sub-per-mille normalization keeps a flat reflector exactly neutral on
        // the sampled grid without changing the chromatic adaptation.
        return SIMD3(rgb.x / d65DisplayP3White.x,
                     rgb.y / d65DisplayP3White.y,
                     rgb.z / d65DisplayP3White.z)
    }

    private static let d65WhiteXYZ: SIMD3<Float> = {
        let white = xyz(spectrum: d65)
        return white / max(white.y, 1e-12)
    }()

    private static let d65DisplayP3White: SIMD3<Float> =
        linearDisplayP3(fromXYZ: d65WhiteXYZ)

    private static func bradfordLMS(fromXYZ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
             0.8951 * value.x + 0.2664 * value.y - 0.1614 * value.z,
            -0.7502 * value.x + 1.7135 * value.y + 0.0367 * value.z,
             0.0389 * value.x - 0.0685 * value.y + 1.0296 * value.z)
    }

    private static func xyz(fromBradfordLMS value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
             0.9869929 * value.x - 0.1470543 * value.y + 0.1599627 * value.z,
             0.4323053 * value.x + 0.5183603 * value.y + 0.0492912 * value.z,
            -0.0085287 * value.x + 0.0400428 * value.y + 0.9684867 * value.z)
    }

}

/// Bounded spectra fitted to the Gaussian prior of the measured-reflectance corpus.
///
/// The engine always evaluates recovery on a fixed-peak chromaticity ray. The resource therefore
/// stores the three peak-channel faces of that anchored cube, each as a 33 x 33 grid of complete
/// full-grid spectra. Face interpolation is stock-independent; each stock subsequently integrates
/// the same recovered spectrum against its own layers.
private final class MeasuredReflectanceTable: @unchecked Sendable {
    static let shared: MeasuredReflectanceTable? = loadBundled()

    let dimension: Int
    let bandCount: Int
    let sourceCount: Int
    let anchor: Float
    let data: [Float]

    init(dimension: Int, bandCount: Int, sourceCount: Int, anchor: Float, data: [Float]) {
        self.dimension = dimension
        self.bandCount = bandCount
        self.sourceCount = sourceCount
        self.anchor = anchor
        self.data = data
    }

    /// Recovers at the table anchor and then follows the engine's existing brightness ray.
    func reflectance(_ input: SIMD3<Float>) -> [Float] {
        let rgb = SIMD3(max(input.x, 0), max(input.y, 0), max(input.z, 0))
        let peak = max(rgb.x, rgb.y, rgb.z)
        guard peak > 0 else { return [Float](repeating: 0, count: bandCount) }
        let rayScale = peak / anchor
        let anchored = rgb / rayScale
        var dominant = 0
        if anchored.y >= anchored[dominant] { dominant = 1 }
        if anchored.z >= anchored[dominant] { dominant = 2 }

        let extent = Float(dimension - 1)
        let x = clamp(anchored[(dominant + 1) % 3] / anchor * extent, 0, extent)
        let y = clamp(anchored[(dominant + 2) % 3] / anchor * extent, 0, extent)
        let xi = min(Int(x), dimension - 2)
        let yi = min(Int(y), dimension - 2)
        let xf = x - Float(xi)
        let yf = y - Float(yi)

        func value(_ dx: Int, _ dy: Int, _ band: Int) -> Float {
            let index = (((dominant * dimension + yi + dy) * dimension + xi + dx)
                         * bandCount + band)
            return data[index]
        }
        var spectrum = [Float](repeating: 0, count: bandCount)
        for band in spectrum.indices {
            let lower = value(0, 0, band) + xf * (value(1, 0, band) - value(0, 0, band))
            let upper = value(0, 1, band) + xf * (value(1, 1, band) - value(0, 1, band))
            spectrum[band] = max((lower + yf * (upper - lower)) * rayScale, 0)
        }
        return spectrum
    }

    private static func loadBundled() -> MeasuredReflectanceTable? {
        if let configured = ProcessInfo.processInfo.environment["FOTUFILM_RESOURCES"] {
            let candidate = URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent("rec2020-reflectance-prior.coeff")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return load(contentsOf: candidate)
            }
        }
        let url: URL?
        #if SWIFT_PACKAGE
        url = Bundle.module.url(forResource: "rec2020-reflectance-prior",
                                withExtension: "coeff")
        #else
        url = Bundle.main.url(forResource: "rec2020-reflectance-prior",
                              withExtension: "coeff")
            ?? URL(fileURLWithPath:
                "Sources/FotufilmCore/Resources/rec2020-reflectance-prior.coeff")
        #endif
        guard let url else { return nil }
        return load(contentsOf: url)
    }

    private static func load(contentsOf url: URL) -> MeasuredReflectanceTable? {
        guard let bytes = try? Data(contentsOf: url), bytes.count >= 24,
              String(data: bytes.prefix(4), encoding: .ascii) == "RPR1" else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        func f32(_ offset: Int) -> Float { Float(bitPattern: u32(offset)) }
        let dimension = Int(u32(4))
        let bandCount = Int(u32(8))
        let sourceCount = Int(u32(12))
        let anchor = f32(16)
        let valueCount = Int(u32(20))
        let expectedCount = 3 * dimension * dimension * bandCount
        guard dimension >= 2, bandCount == SpectralGrid.count, sourceCount > 0,
              anchor > 0, anchor.isFinite, valueCount == expectedCount,
              bytes.count == 24 + valueCount * 4 else { return nil }
        var offset = 24
        var data = [Float](repeating: 0, count: valueCount)
        for i in data.indices {
            let value = f32(offset)
            guard value.isFinite, value >= 0, value <= 1 else { return nil }
            data[i] = value
            offset += 4
        }
        return MeasuredReflectanceTable(dimension: dimension, bandCount: bandCount,
                                        sourceCount: sourceCount, anchor: anchor, data: data)
    }
}
