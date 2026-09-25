import XCTest
import FotufilmHalide
@testable import FotufilmCore

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
}

extension CrystalGrainTests {
    /// Prints the population the model derives for the installed stocks named in
    /// FOTUFILM_CRYSTAL_REPORT (comma separated), with the granularity it states every tenth of
    /// a density — the population the Film grain model lays.
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
