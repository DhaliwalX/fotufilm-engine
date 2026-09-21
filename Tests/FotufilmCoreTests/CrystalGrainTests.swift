import XCTest
import FotufilmHalide
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class CrystalGrainTests: XCTestCase {

    private static let stocks: [(String, FilmStock)] = [
        ("negative", TestStocks.negative), ("reversal", TestStocks.reversal),
        ("monochrome", TestStocks.monochrome),
    ]

    private static let candidate = CrystalGrainPopulation(
        radiusSpan: 3, sublayerShares: [0.20, 0.25, 0.25, 0.30], coatingDensityScale: 1)

    func testAuthoredPopulationChangesGeometryAndPreservesRMSAnchor() {
        for (name, original) in Self.stocks {
            var stock = original
            stock.crystalGrainPopulation = original.isReversal
                ? CrystalGrainPopulation(radiusSpan: 3,
                                         sublayerShares: original.crystalGrainPopulation.sublayerShares,
                                         coatingDensityScale: 1) : Self.candidate
            for layer in 0..<3 {
                let baseline = CrystalGrainModel(stock: original, layer: layer)
                let model = CrystalGrainModel(stock: stock, layer: layer)
                XCTAssertNotEqual(model.bins.map(\.cloudRadiusMM),
                                  baseline.bins.map(\.cloudRadiusMM), name)
                XCTAssertEqual(model.sigma(netDensity: model.readNetDensity),
                               baseline.readSigma, accuracy: baseline.readSigma * 1e-3, name)
                XCTAssertLessThan(model.fitError, 0.1, "\(name): \(model.report)")
                let radii = model.bins.map(\.cloudRadiusMM).filter { $0 > 0 }
                XCTAssertLessThanOrEqual(radii.max()! / radii.min()!, 3.0001)
            }
        }
    }

    func testDenserCoatingPreservesMeanAndReducesVariance() {
        for (_, original) in Self.stocks {
            var stock = original
            stock.crystalGrainPopulation = CrystalGrainPopulation(
                radiusSpan: original.crystalGrainPopulation.radiusSpan,
                sublayerShares: original.crystalGrainPopulation.sublayerShares, coatingDensityScale: 2)
            for layer in 0..<3 {
                let a = CrystalGrainModel(stock: original, layer: layer)
                let b = CrystalGrainModel(stock: stock, layer: layer)
                for (before, after) in zip(a.bins, b.bins) {
                    XCTAssertEqual(after.cloudRadiusMM, before.cloudRadiusMM)
                    XCTAssertEqual(after.crystalsPerMM2, before.crystalsPerMM2 * 2)
                    XCTAssertEqual(after.dyePerCloud, before.dyePerCloud / 2)
                    XCTAssertEqual(after.pool, before.pool)
                }
                for exposure: Float in [-2, -1, 0, 1, 2] {
                    XCTAssertEqual(a.meanDensity(logExposure: exposure),
                                   b.meanDensity(logExposure: exposure), accuracy: 1e-6)
                }
                for density: Float in [0.2, 0.5, 1] {
                    XCTAssertEqual(b.sigma(netDensity: density),
                                   a.sigma(netDensity: density) / sqrt(2), accuracy: 1e-6)
                }
            }
        }
    }

    func testProcessUsesReferencePopulationAndKeepsCoatingScale() {
        var reference = TestStocks.negative
        reference.crystalGrainPopulation = Self.candidate
        var developed = reference
        for layer in 0..<3 { developed.curves[layer].gamma *= 1.1 }
        // A process condition cannot replace the reference coating's geometry.
        developed.crystalGrainPopulation = TestStocks.negative.crystalGrainPopulation
        for layer in 0..<3 {
            let a = CrystalGrainModel(stock: developed, reference: reference, layer: layer)
            var denser = reference
            denser.crystalGrainPopulation = CrystalGrainPopulation(
                radiusSpan: Self.candidate.radiusSpan, sublayerShares: Self.candidate.sublayerShares,
                coatingDensityScale: 2)
            let b = CrystalGrainModel(stock: developed, reference: denser, layer: layer)
            let ref = CrystalGrainModel(stock: reference, layer: layer)
            XCTAssertEqual(a.bins.map(\.cloudRadiusMM), ref.bins.map(\.cloudRadiusMM))
            XCTAssertEqual(a.bins.map(\.crystalsPerMM2), ref.bins.map(\.crystalsPerMM2))
            XCTAssertEqual(b.bins.map(\.cloudRadiusMM), a.bins.map(\.cloudRadiusMM))
            XCTAssertEqual(b.bins.map(\.crystalsPerMM2), a.bins.map { $0.crystalsPerMM2 * 2 })
            XCTAssertEqual(b.sigma(netDensity: 1), a.sigma(netDensity: 1) / sqrt(2), accuracy: 1e-6)
        }
    }

    func testPopulationPackRoundTrip() throws {
        for population in [TestStocks.negative.crystalGrainPopulation, Self.candidate] {
            var stock = TestStocks.negative
            stock.crystalGrainPopulation = population
            let data = try JSONEncoder().encode(FilmStockDefinition(id: "test", stock: stock))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let authored = try XCTUnwrap(json["crystalGrainPopulation"] as? [String: Any])
            XCTAssertEqual(Set(authored.keys), ["radiusSpan", "sublayerShares", "coatingDensityScale"])
            let decoded = try JSONDecoder().decode(FilmStockDefinition.self, from: data).validated()
            XCTAssertEqual(decoded.stock.crystalGrainPopulation, population)
        }
    }

    func testMissingPopulationFieldsAreRejected() throws {
        let data = try JSONEncoder().encode(FilmStockDefinition(id: "test", stock: TestStocks.negative))
        let complete = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["crystalGrainPopulation", "radiusSpan", "sublayerShares", "coatingDensityScale"] {
            var json = complete
            if field == "crystalGrainPopulation" {
                json.removeValue(forKey: field)
            } else {
                var population = try XCTUnwrap(json["crystalGrainPopulation"] as? [String: Any])
                population.removeValue(forKey: field)
                json["crystalGrainPopulation"] = population
            }
            let incomplete = try JSONSerialization.data(withJSONObject: json)
            XCTAssertThrowsError(try JSONDecoder().decode(FilmStockDefinition.self, from: incomplete)) { error in
                guard case DecodingError.keyNotFound(let key, _) = error else {
                    return XCTFail("expected missing-field failure, got \(error)")
                }
                XCTAssertEqual(key.stringValue, field)
            }
        }
    }

    func testMalformedPopulationIsRejectedDuringPackDecode() throws {
        let baseline = try JSONEncoder().encode(FilmStockDefinition(id: "test", stock: TestStocks.negative))
        for override: [String: Any] in [
            ["radiusSpan": 0], ["radiusSpan": 21], ["sublayerShares": [0.2, 0.8]],
            ["sublayerShares": [0.2, 0.2, 0.2, 0.2]],
            ["sublayerShares": [0, 0.3, 0.3, 0.4]],
            ["coatingDensityScale": 0], ["coatingDensityScale": 5]
        ] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
            var population = try XCTUnwrap(json["crystalGrainPopulation"] as? [String: Any])
            population.merge(override) { _, authored in authored }
            json["crystalGrainPopulation"] = population
            let data = try JSONSerialization.data(withJSONObject: json)
            XCTAssertThrowsError(try JSONDecoder().decode(FilmStockDefinition.self, from: data)) { error in
                guard case DecodingError.dataCorrupted = error else {
                    return XCTFail("expected invalid-population failure, got \(error)")
                }
            }
        }
    }

    /// The sublayers the kernel renders — each drawing on one pool — form the record's curve
    /// to within a tenth of a density over six decades, and the model's own mean is that fit.
    /// Fog is set aside: the model develops it, the curve's D-min already holds it.
    func testPopulationReproducesTheCurve() {
        for (name, fogged) in Self.stocks {
            var stock = fogged
            stock.grainFogDensity = 0
            for layer in 0..<3 {
                let model = CrystalGrainModel(stock: stock, layer: layer)
                XCTAssertLessThan(model.fitError, 0.1, "\(name) layer \(layer): \(model.report)")
                let curve = stock.curves[layer]
                var worst: Float = 0
                for step in 0...120 {
                    let x = -3 + Float(step) * 0.05
                    let formed = curve.density(logExposure: x) - curve.dMin
                    let mean = model.meanDensity(logExposure: x)
                    let positive = stock.isReversal ? (curve.dMax - curve.dMin) - mean : mean
                    worst = max(worst, abs(positive - formed))
                }
                XCTAssertLessThanOrEqual(worst, model.fitError + 0.005,
                                         "\(name) layer \(layer) sublayers: \(model.report)")
            }
        }
    }

    /// The sheet's figure is what the population reads back at the sheet's density, and the
    /// population it implies is a physical one: microns of cloud, crystals by the dozen per
    /// square micron at most.
    func testSheetGranularityAnchorsThePopulation() {
        for (name, stock) in Self.stocks {
            for layer in 0..<3 {
                let model = CrystalGrainModel(stock: stock, layer: layer)
                let stated = stock.grainStrength * stock.grainLayerWeights[layer]
                XCTAssertEqual(model.sigma(netDensity: model.readNetDensity), stated,
                               accuracy: stated * 1e-3, "\(name) layer \(layer)")
                let coated = model.bins.filter { $0.cloudRadiusMM > 0 }
                XCTAssertGreaterThanOrEqual(coated.count, 3, name)
                XCTAssertEqual(coated[0].cloudRadiusMM,
                               stock.grainSizeMM * stock.grainLayerSizeRatio[layer],
                               accuracy: 1e-6, "the fastest sublayer lays the scan-fitted clump")
                for bin in coated {
                    XCTAssertGreaterThan(bin.cloudRadiusMM, 0.0003, name)
                    XCTAssertLessThan(bin.crystalsPerMM2 * 1e-6, 200, "\(name): \(model.report)")
                    XCTAssertGreaterThan(bin.crystalsPerMM2 * 1e-6, 0.01, "\(name): \(model.report)")
                }
                // Coarser as they get faster.
                for pair in zip(coated, coated.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(pair.0.cloudRadiusMM, pair.1.cloudRadiusMM, name)
                }
            }
        }
    }

    /// A chromogenic negative's granularity peaks above base and falls as its fast sublayer's
    /// pool draws down; silver, with no pool, only rises; a reversal's rises with its positive
    /// density and levels off towards D-max, the saturating rise Kodak's E100 sheet shows.
    func testGranularityAgainstDensityFollowsTheMaterial() {
        let negative = CrystalGrainModel(stock: TestStocks.negative, layer: 1)
        let peak = (2...10).map { negative.sigma(netDensity: Float($0) * 0.05) }.max()!
        XCTAssertGreaterThan(peak, negative.sigma(netDensity: 1.0) * 1.05, negative.report)
        XCTAssertGreaterThan(negative.sigma(netDensity: 1.0), negative.sigma(netDensity: 1.8),
                             negative.report)
        let silver = CrystalGrainModel(stock: TestStocks.monochrome, layer: 0)
        var previous: Float = 0
        for step in 1...15 {
            let sigma = silver.sigma(netDensity: Float(step) * 0.1)
            XCTAssertGreaterThanOrEqual(sigma, previous * 0.999, silver.report)
            previous = sigma
        }
        let reversal = CrystalGrainModel(stock: TestStocks.reversal, layer: 1)
        XCTAssertLessThan(reversal.sigma(netDensity: 0.3), reversal.sigma(netDensity: 1.0),
                          reversal.report)
        let range = TestStocks.reversal.curves[1].dMax - TestStocks.reversal.curves[1].dMin
        let rise = reversal.sigma(netDensity: 1.0) - reversal.sigma(netDensity: 0.3)
        let tail = reversal.sigma(netDensity: range * 0.98) - reversal.sigma(netDensity: 1.0)
        XCTAssertLessThan(tail, rise * 0.5, reversal.report)
    }

    /// Against the two sheets that publish a curve — Kodak's granularity against density for
    /// Vision3 250D and 500T, which the packs carry per record as `grainDensityProfile` — the
    /// population's own curve stays within the plots' reading accuracy between 0.1 and 2.0
    /// above base. The blue record's second rise near net 1.3 is the one feature a
    /// two-population model cannot make, which is where the bound is set.
    func testKodakSheetCurves() throws {
        for id in ["vision250d", "vision500t"] {
            guard let stock = FilmStock.named(id) else {
                throw XCTSkip("\(id) is not installed; set FOTUFILM_STOCKS")
            }
            for layer in 0..<3 {
                let model = CrystalGrainModel(stock: stock, layer: layer)
                let anchor = model.readNetDensity
                var worst: Float = 0
                for step in 1...20 {
                    let net = Float(step) * 0.1
                    let modelled = model.sigma(netDensity: net) / model.sigma(netDensity: anchor)
                    let sheet = stock.grainDensityModulation(layer: layer, netDensity: net)
                        / stock.grainDensityModulation(layer: layer, netDensity: anchor)
                    worst = max(worst, abs(log(modelled / sheet)))
                }
                XCTAssertLessThan(worst, 0.42, "\(id) layer \(layer): \(model.report)")
            }
        }
    }

    func testInvocationPacksTheModelOnlyWhenAsked() {
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        let plain = FilmEngineInvocation(stock: stock, options: options, width: 512, height: 512)
        XCTAssertEqual(plain.featureMask & FilmEngineFeature.discGrain, 0)
        XCTAssertEqual(plain.configuration.count, FilmEngineInvocation.configurationCount)
        let binOffset = FilmEngineInvocation.crystalGrainBinOffset
        let lambdaOffset = FilmEngineInvocation.crystalGrainLambdaOffset
        let printOffset = Int(FOTUFILM_CONFIG_CRYSTAL_PRINT_GRAIN)
        XCTAssertEqual(binOffset, Int(FOTUFILM_CONFIG_CRYSTAL_GRAIN_BIN))
        XCTAssertEqual(lambdaOffset, Int(FOTUFILM_CONFIG_CRYSTAL_GRAIN_LAMBDA))
        XCTAssertEqual(binOffset, Int(FOTUFILM_CONFIG_GRAIN_REVERSAL_PROFILE) + 2)
        XCTAssertEqual(lambdaOffset, binOffset + 3 * CrystalGrainModel.binCount * 4)
        XCTAssertEqual(printOffset, lambdaOffset + 3 * CrystalGrainModel.binCount * CrystalGrainModel.samples)
        // The print stage's four, the two preflashes, the byte frames' two primaries, and
        // the per-record grain rows, all appended past the print grain.
        XCTAssertEqual(FilmEngineInvocation.configurationCount,
                       printOffset + 8 + Int(FOTUFILM_CONFIG_GRAIN_DENSITY_RECORDS_COUNT))
        for slot in binOffset..<printOffset {
            XCTAssertEqual(plain.configuration[slot], 0)
        }
        for slot in printOffset..<(printOffset + 3) {
            XCTAssertEqual(plain.configuration[slot], 0)
        }
        XCTAssertEqual(plain.configuration[Int(FOTUFILM_CONFIG_GRAIN_MODE)], 0)

        options.grainModel = .crystals
        let crystals = FilmEngineInvocation(stock: stock, options: options, width: 512, height: 512)
        XCTAssertNotEqual(crystals.featureMask & FilmEngineFeature.discGrain, 0)
        XCTAssertEqual(crystals.featureMask & FilmEngineFeature.grainMottle, 0)
        XCTAssertEqual(crystals.configuration[Int(FOTUFILM_CONFIG_GRAIN_MODE)], 2)
        let pxPerMM = Float(512) / options.format.frameHeightMM
        var widest: Float = 0
        for layer in 0..<3 {
            let model = CrystalGrainModel(stock: stock, layer: layer)
            let tables = model.countTable(pxPerMM: pxPerMM)
            for bin in 0..<CrystalGrainModel.binCount {
                let base = binOffset + (layer * CrystalGrainModel.binCount + bin) * 4
                let sigma = crystals.configuration[base]
                widest = max(widest, sigma)
                XCTAssertEqual(crystals.configuration[base + 1],
                               model.densityPerCloud(bin: bin, pxPerMM: pxPerMM), accuracy: 1e-9)
                XCTAssertEqual(crystals.configuration[base + 2], model.bins[bin].pool, accuracy: 1e-9)
                let factor = crystals.configuration[base + 3]
                if model.bins[bin].pool > 0 && model.bins[bin].cloudRadiusMM > 0 {
                    // Below its linear limit q / C, the concave pool's, and near it for
                    // clouds that are small against their pool.
                    let linear = crystals.configuration[base + 1] / model.bins[bin].pool
                    XCTAssertGreaterThan(factor, linear * 0.5)
                    XCTAssertLessThanOrEqual(factor, linear * 1.0001)
                } else {
                    XCTAssertEqual(factor, crystals.configuration[base + 1])
                }
                let table = lambdaOffset
                    + (layer * CrystalGrainModel.binCount + bin) * CrystalGrainModel.samples
                XCTAssertEqual(Array(crystals.configuration[table..<(table + CrystalGrainModel.samples)]),
                               tables[bin])
                // Counts rise with the developed density on a negative.
                XCTAssertGreaterThan(tables[bin].last!, tables[bin].first!)
            }
        }
        XCTAssertGreaterThanOrEqual(
            Float(crystals.configuration[Int(FOTUFILM_CONFIG_GRAIN_RADIUS)]),
            Float(FilmEngineInvocation.gaussianRadius(widest)))

        // Grain off leaves nothing to develop, whatever the model.
        options.grainScale = 0
        let off = FilmEngineInvocation(stock: stock, options: options, width: 512, height: 512)
        XCTAssertEqual(off.featureMask & FilmEngineFeature.discGrain, 0)
        XCTAssertEqual(off.configuration[Int(FOTUFILM_CONFIG_GRAIN_MODE)], 0)
    }

    /// Grain that is `s` times stronger is coated as a grainier emulsion: wider clouds, each
    /// carrying more, fewer of them — the sheet figure times `s` at the read density.
    func testGrainScaleCoatsAGrainierEmulsion() {
        let stock = TestStocks.negative
        let plain = CrystalGrainModel(stock: stock, layer: 1)
        let doubled = CrystalGrainModel(stock: stock, layer: 1, grainScale: 2)
        XCTAssertEqual(doubled.sigma(netDensity: 1), plain.sigma(netDensity: 1) * 2,
                       accuracy: plain.sigma(netDensity: 1) * 0.01)
        XCTAssertEqual(doubled.bins[0].cloudRadiusMM, plain.bins[0].cloudRadiusMM * 2, accuracy: 1e-6)
        // Four times the dye per cloud, a little more where the wider cloud loses more of
        // itself to the 48 µm aperture; a quarter the crystals.
        let dye = doubled.bins[0].dyePerCloud / plain.bins[0].dyePerCloud
        XCTAssertGreaterThan(dye, 3.9)
        XCTAssertLessThan(dye, 5)
        XCTAssertEqual(plain.bins[0].crystalsPerMM2 / doubled.bins[0].crystalsPerMM2, dye,
                       accuracy: 0.02)
    }

    // MARK: - Rendered

    private func uniform(_ stock: FilmStock, exposure: Float, pxPerMM: Float, seed: UInt64,
                         model: GrainModel, sideMM: Float = 1.2) -> ImageBuffer {
        var options = FotufilmEngine.Options()
        options.sceneIlluminantKelvin = stock.referenceIlluminantKelvin
        options.format = FilmFormat(name: "crystal bench", frameHeightMM: sideMM)
        options.halationScale = 0
        options.couplerScale = 0
        options.seed = seed
        options.grainModel = model
        let side = Int(sideMM * pxPerMM)
        var image = ImageBuffer(width: side, height: side)
        for c in 0..<3 { for i in 0..<image.pixelCount { image.planes[c][i] = exposure } }
        return FotufilmEngine(stock: stock, options: options).developNegative(linearRGB: image)
    }

    private func moments(_ plane: [Float]) -> (mean: Float, sigma: Float) {
        let mean = plane.reduce(0, +) / Float(plane.count)
        let variance = plane.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(plane.count)
        return (mean, variance.squareRoot())
    }

    /// The rendered field reads back the population's own granularity through the 48 µm
    /// aperture, at the sheet's density and away from it, on a lattice that resolves the
    /// clouds and on one that does not.
    func testRenderedGranularityMatchesThePopulation() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        for (name, stock) in Self.stocks {
            for pxPerMM: Float in [157.5, 500] {
                let measured = GranularityMeter.ratio(stock, pxPerMM: pxPerMM, model: .crystals)
                XCTAssertEqual(measured, 1, accuracy: 0.08, "\(name) at \(pxPerMM) px/mm")
                let thin = GranularityMeter.ratio(stock, pxPerMM: pxPerMM, model: .crystals,
                                                  exposure: 0.18 * 0.25)
                XCTAssertEqual(thin, 1, accuracy: 0.12, "\(name) thin at \(pxPerMM) px/mm")
            }
        }
    }

    /// The population forms the image from dye clouds whose mean reproduces the curve
    /// within the population's fit error. Fog is set aside as in testPopulationReproducesTheCurve.
    func testToneReproducesTheCurve() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        for (name, fogged) in Self.stocks {
            var stock = fogged
            stock.grainFogDensity = 0
            for exposure: Float in [0.18 * 0.1, 0.18, 0.18 * 8] {
                let grained = uniform(stock, exposure: exposure, pxPerMM: 300, seed: 11,
                                      model: .crystals)
                var flat = FotufilmEngine.Options()
                flat.sceneIlluminantKelvin = stock.referenceIlluminantKelvin
                flat.format = FilmFormat(name: "crystal bench", frameHeightMM: 1.2)
                flat.halationScale = 0
                flat.couplerScale = 0
                flat.grainScale = 0
                var image = ImageBuffer(width: grained.width, height: grained.height)
                for c in 0..<3 { for i in 0..<image.pixelCount { image.planes[c][i] = exposure } }
                let reference = FotufilmEngine(stock: stock, options: flat)
                    .developNegative(linearRGB: image)
                for c in 0..<3 {
                    let withGrain = moments(grained.planes[c])
                    let without = moments(reference.planes[c])
                    let model = CrystalGrainModel(stock: stock, layer: c)
                    XCTAssertEqual(withGrain.mean, without.mean, accuracy: model.fitError + 0.02,
                                   "\(name) layer \(c) at \(exposure)")
                    XCTAssertGreaterThan(withGrain.sigma, 0, name)
                }
            }
        }
    }

    /// The finite stochastic pool and the population fit must have the same ensemble mean.
    /// Test the fitted expectation, not just the much looser characteristic-curve fit error.
    func testRenderedMeanMatchesPopulationAcrossSampling() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        for stock in [TestStocks.negative, TestStocks.reversal] {
            for pxPerMM: Float in [250, 1500] {
                let side = 768
                var options = FotufilmEngine.Options()
                options.format = FilmFormat(name: "population mean", frameHeightMM: Float(side) / pxPerMM)
                options.sceneIlluminantKelvin = stock.referenceIlluminantKelvin
                options.halationScale = 0
                options.couplerScale = 0
                options.seed = 11
                options.grainScale = 0
                var input = ImageBuffer(width: side, height: side)
                for c in 0..<3 { input.planes[c] = [Float](repeating: 0.18, count: side * side) }
                let flat = FotufilmEngine(stock: stock, options: options).developNegative(linearRGB: input)
                options.grainScale = 1
                options.grainModel = .crystals
                let image = FotufilmEngine(stock: stock, options: options).developNegative(linearRGB: input)
                for c in 0..<3 {
                    let model = CrystalGrainModel(stock: stock, layer: c)
                    let curve = stock.curves[c]
                    let net = flat.planes[c][side * side / 2] - curve.dMin
                    let amount = min(max(net / (curve.dMax - curve.dMin), 0), 1)
                    let index = amount * Float(CrystalGrainModel.samples - 1)
                    let lo = min(Int(index), CrystalGrainModel.samples - 2)
                    let fraction = index - Float(lo)
                    let tables = model.countTable(pxPerMM: pxPerMM)
                    var expected = curve.dMin
                    for bin in 0..<CrystalGrainModel.binCount {
                        let lambda = tables[bin][lo] * (1 - fraction) + tables[bin][lo + 1] * fraction
                        let demand = lambda * model.densityPerCloud(bin: bin, pxPerMM: pxPerMM)
                        let pool = model.bins[bin].pool
                        expected += pool > 0 ? pool * (1 - exp(-demand / pool)) : demand
                    }
                    // Exclude the clamped image boundary and accumulate in Double.
                    var sum = 0.0
                    for y in 48..<(side - 48) {
                        for x in 48..<(side - 48) { sum += Double(image.planes[c][y * side + x]) }
                    }
                    let mean = Float(sum / Double((side - 96) * (side - 96)))
                    XCTAssertEqual(mean, expected, accuracy: 0.006,
                                   "\(stock.name) record \(c), \(pxPerMM) px/mm")
                }
            }
        }
    }

    /// Where little developed the grain is the fast sublayer's few coarse clouds; where most
    /// did, a haze of fine ones — so the field's correlation length shortens with density.
    func testTextureCoarsensWhereLittleDeveloped() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        let stock = TestStocks.negative
        func lagOneCorrelation(_ image: ImageBuffer, plane: Int) -> Float {
            let values = image.planes[plane]
            let mean = values.reduce(0, +) / Float(values.count)
            var zero: Float = 0, one: Float = 0
            for y in 0..<image.height {
                for x in 0..<(image.width - 1) {
                    let a = values[y * image.width + x] - mean
                    let b = values[y * image.width + x + 1] - mean
                    zero += a * a
                    one += a * b
                }
            }
            return one / zero
        }
        let thin = uniform(stock, exposure: 0.18 * 0.08, pxPerMM: 500, seed: 3, model: .crystals)
        let dense = uniform(stock, exposure: 0.18 * 16, pxPerMM: 500, seed: 3, model: .crystals)
        for c in 0..<3 {
            XCTAssertGreaterThan(lagOneCorrelation(thin, plane: c),
                                 lagOneCorrelation(dense, plane: c) + 0.05, "layer \(c)")
        }
        let other = uniform(stock, exposure: 0.18 * 0.08, pxPerMM: 500, seed: 4, model: .crystals)
        XCTAssertNotEqual(thin.planes[1], other.planes[1])
        let again = uniform(stock, exposure: 0.18 * 0.08, pxPerMM: 500, seed: 3, model: .crystals)
        XCTAssertEqual(thin.planes[1], again.planes[1])
    }

    #if canImport(Metal)
    /// Both schedules develop the same population to the same granularity and tone; they draw
    /// their own hashes, so the fields agree in their statistics rather than pixel for pixel.
    func testCPUAndMetalAgree() throws {
        try checkCPUAndMetal(stock: TestStocks.negative)
    }

    func testAuthoredPopulationCPUAndMetalAgree() throws {
        var stock = TestStocks.negative
        stock.crystalGrainPopulation = CrystalGrainPopulation(
            radiusSpan: 3, sublayerShares: Self.candidate.sublayerShares, coatingDensityScale: 2)
        try checkCPUAndMetal(stock: stock)
    }

    private func checkCPUAndMetal(stock: FilmStock) throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        var options = FotufilmEngine.Options()
        options.sceneIlluminantKelvin = stock.referenceIlluminantKelvin
        options.format = FilmFormat(name: "crystal bench", frameHeightMM: 1.2)
        options.halationScale = 0
        options.couplerScale = 0
        options.seed = 5
        options.grainModel = .crystals
        options.stage = .negative
        let side = Int(1.2 * 400)
        var image = ImageBuffer(width: side, height: side)
        var rgba = [Float](repeating: 1, count: side * side * 4)
        for i in 0..<image.pixelCount {
            for c in 0..<3 { image.planes[c][i] = 0.18; rgba[i * 4 + c] = 0.18 }
        }
        let cpu = FotufilmEngine(stock: stock, options: options).developNegative(linearRGB: image)
        let metal = try XCTUnwrap(gpu.processLinearFloat(
            rgba, width: side, height: side, stock: stock, options: options))
        for c in 0..<3 {
            let a = moments(cpu.planes[c])
            let b = moments((0..<image.pixelCount).map { metal[$0 * 4 + c] })
            XCTAssertEqual(a.mean, b.mean, accuracy: 0.01, "layer \(c) mean")
            XCTAssertEqual(a.sigma, b.sigma, accuracy: a.sigma * 0.08, "layer \(c) sigma")
        }
    }
    #endif

    /// A pushed or pulled development refits the development stage's developability and per-sublayer
    /// gains to the measured curve with the population held. Granularity at mid-density rises with
    /// push and falls with pull.
    func testDevelopmentPushPullRefit() throws {
        guard let delta = FilmStock.named("delta3200") else {
            throw XCTSkip("delta3200 is not installed")
        }
        let ref = CrystalGrainModel(stock: delta, layer: 0)
        XCTAssertLessThan(ref.fitError, 0.1, "delta3200 unpushed: \(ref.report)")
        let sigmaRef = ref.sigma(netDensity: 1.0)

        // Pull 2 (-2 stops)
        let pull2Stock = try delta.pushed(stops: -2)
        let pull2 = CrystalGrainModel(stock: pull2Stock, reference: delta, layer: 0)
        XCTAssertLessThan(pull2.fitError, 0.15, "delta3200 pull 2: \(pull2.report)")
        XCTAssertLessThan(pull2.sigma(netDensity: 1.0), sigmaRef, "pull 2 granularity should fall")

        // Push 1 (+1 stop)
        let push1Stock = try delta.pushed(stops: 1)
        let push1 = CrystalGrainModel(stock: push1Stock, reference: delta, layer: 0)
        XCTAssertLessThan(push1.fitError, 0.15, "delta3200 push 1: \(push1.report)")
        XCTAssertGreaterThan(push1.sigma(netDensity: 1.0), sigmaRef, "push 1 granularity should rise")

        // Push 2 (+2 stops)
        let push2Stock = try delta.pushed(stops: 2)
        let push2 = CrystalGrainModel(stock: push2Stock, reference: delta, layer: 0)
        XCTAssertLessThan(push2.fitError, 0.15, "delta3200 push 2: \(push2.report)")
        XCTAssertGreaterThan(push2.sigma(netDensity: 1.0), push1.sigma(netDensity: 1.0), "push 2 > push 1")
    }

    /// Paper grain is packed only when an emulsion paper is exposed (not for screen, scans, or negative viewing).
    /// The crystals per pixel scale inversely with frame pixel dimensions squared for a fixed sheet size.
    func testPrintStagePacking() {
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        options.grainModel = .crystals

        // Screen output: no paper crystals
        options.paper = .screen
        options.stage = .print
        let screen = FilmEngineInvocation(stock: stock, options: options, width: 512, height: 512)
        let printOffset = Int(FOTUFILM_CONFIG_CRYSTAL_PRINT_GRAIN)
        XCTAssertEqual(screen.configuration[printOffset], 0)

        // Negative stage: no paper crystals
        options.paper = .ektacolorEdge
        options.stage = .negative
        let negStage = FilmEngineInvocation(stock: stock, options: options, width: 512, height: 512)
        XCTAssertEqual(negStage.configuration[printOffset], 0)

        // Print paper: paper crystals active
        options.stage = .print
        let print512 = FilmEngineInvocation(stock: stock, options: options, width: 512, height: 512)
        let crystals512 = print512.configuration[printOffset]
        XCTAssertGreaterThan(crystals512, 0)

        // Double resolution -> pixel area is 1/4 -> 1/4 the crystals per pixel
        let print1024 = FilmEngineInvocation(stock: stock, options: options, width: 1024, height: 1024)
        let crystals1024 = print1024.configuration[printOffset]
        XCTAssertEqual(crystals1024, crystals512 / 4, accuracy: crystals512 * 0.01)
    }

    /// In print mode, crystal grain model lays Poisson paper grain across the paper activation.
    /// Clump mode with grainScale 0 has none.
    func testPaperGrainInPrint() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        options.sceneIlluminantKelvin = stock.referenceIlluminantKelvin
        options.paper = .ektacolorEdge
        options.stage = .print
        options.seed = 42
        options.halationScale = 0
        options.couplerScale = 0

        let side = 128
        var image = ImageBuffer(width: side, height: side)
        for c in 0..<3 { for i in 0..<image.pixelCount { image.planes[c][i] = 0.18 } }

        options.grainModel = .crystals
        let crystalsRender = FotufilmEngine(stock: stock, options: options).process(linearRGB: image)
        let crystalsMoments = moments(crystalsRender.planes[1])

        options.grainModel = .clumpField
        options.grainScale = 0
        let flatRender = FotufilmEngine(stock: stock, options: options).process(linearRGB: image)
        let flatMoments = moments(flatRender.planes[1])

        // Mean tone is preserved through print
        XCTAssertEqual(crystalsMoments.mean, flatMoments.mean, accuracy: 0.02)
        // Crystals path has noise from the paper emulsion; flat clump path has zero noise
        XCTAssertGreaterThan(crystalsMoments.sigma, 1e-5)
        XCTAssertEqual(flatMoments.sigma, 0, accuracy: 1e-5)
    }

    #if canImport(Metal)
    func testPrintCPUAndMetalAgree() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        options.sceneIlluminantKelvin = stock.referenceIlluminantKelvin
        options.paper = .ektacolorEdge
        options.stage = .print
        options.seed = 7
        options.halationScale = 0
        options.couplerScale = 0
        options.grainModel = .crystals

        let side = 128
        var image = ImageBuffer(width: side, height: side)
        var rgba = [Float](repeating: 1, count: side * side * 4)
        for i in 0..<image.pixelCount {
            for c in 0..<3 { image.planes[c][i] = 0.18; rgba[i * 4 + c] = 0.18 }
        }
        let cpu = FotufilmEngine(stock: stock, options: options).process(linearRGB: image)
        let metal = try XCTUnwrap(gpu.processLinearFloat(
            rgba, width: side, height: side, stock: stock, options: options))
        for c in 0..<3 {
            let a = moments(cpu.planes[c])
            let b = moments((0..<image.pixelCount).map { metal[$0 * 4 + c] })
            XCTAssertEqual(a.mean, b.mean, accuracy: 0.02, "channel \(c) print mean")
            XCTAssertEqual(a.sigma, b.sigma, accuracy: a.sigma * 0.20, "channel \(c) print sigma")
        }
    }
    #endif
}

extension CrystalGrainTests {
    /// Prints the population the model derives for the installed stocks named in
    /// FOTUFILM_CRYSTAL_REPORT (comma separated), with the granularity it states every tenth of
    /// a density — the numbers docs/crystal-grain.md quotes.
    func testReportsThePopulation() throws {
        guard let names = ProcessInfo.processInfo.environment["FOTUFILM_CRYSTAL_REPORT"] else {
            throw XCTSkip("set FOTUFILM_CRYSTAL_REPORT to a list of stock ids")
        }
        for id in names.split(separator: ",").map(String.init) {
            let stock = try XCTUnwrap(FilmStock.named(id), id)
            for layer in (stock.isMonochrome ? [0] : [0, 1, 2]) {
                let model = CrystalGrainModel(stock: stock, layer: layer)
                print("== \(id) layer \(layer)\n\(model.report)")
                let nets = stride(from: Float(0.1), through: 2.0, by: 0.1)
                    .filter { $0 < 0.95 * (stock.curves[layer].dMax - stock.curves[layer].dMin) }
                print("   net D  " + nets.map { String(format: "%5.2f", $0) }.joined(separator: " "))
                print("   σ48 e-3" + nets.map { String(format: "%5.1f", model.sigma(netDensity: $0) * 1000) }
                    .joined(separator: " "))
                print("   sheet  " + nets.map {
                    String(format: "%5.1f", stock.grainDensityModulation(layer: layer, netDensity: $0)
                        * stock.grainStrength * stock.grainLayerWeights[layer] * 1000)
                }.joined(separator: " "))
            }
        }
    }
}
