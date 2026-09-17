import XCTest
@testable import FotufilmCore

final class ECN2ProcessTests: XCTestCase {

    /// Verifies that native motion-picture negative stocks developed in Process ECN-2
    /// exhibit the characteristic aim gamma of ~0.50–0.55 across layers.
    func testNativeECN2StockAimGamma() throws {
        for id in ["vision500t", "vision250d", "eterna500"] {
            let stock = try XCTUnwrap(FilmStock.named(id), "Stock \(id) must load")
            XCTAssertEqual(stock.curves.count, 3, "\(id) must have 3 dye-forming records")

            var effectiveGammas: [Float] = []
            for (channel, curve) in stock.curves.enumerated() {
                // Effective midtone slope across 1.0 log-exposure decade (from -1.0 to 0.0)
                let d0 = curve.density(logExposure: 0.0)
                let dm1 = curve.density(logExposure: -1.0)
                let effectiveGamma = d0 - dm1
                effectiveGammas.append(effectiveGamma)
                XCTAssertGreaterThan(effectiveGamma, 0.40, "\(id) channel \(channel) gamma too low")
                XCTAssertLessThan(effectiveGamma, 0.60, "\(id) channel \(channel) gamma too high")
            }

            let meanGamma = effectiveGammas.reduce(0, +) / Float(effectiveGammas.count)
            XCTAssertEqual(meanGamma, 0.52, accuracy: 0.03,
                           "\(id): ECN-2 aim gamma must center around ~0.52 (found \(meanGamma))")
        }
    }

    /// Verifies that C-41 still stocks exhibit a distinctly higher gamma (>= 0.60),
    /// consistent with still negative development for RA-4 paper or direct scanning.
    func testC41StillStockHigherGammaThanECN2() throws {
        for id in ["portra400", "gold200"] {
            let stock = try XCTUnwrap(FilmStock.named(id), "Stock \(id) must load")
            let redGamma = stock.curves[0].gamma + (stock.curves[0].secondary?.gamma ?? 0)
            let greenGamma = stock.curves[1].gamma + (stock.curves[1].secondary?.gamma ?? 0)
            let meanRG = (redGamma + greenGamma) / 2.0
            XCTAssertGreaterThanOrEqual(meanRG, 0.60,
                                        "\(id): C-41 still stock contrast must be >= 0.60 (found \(meanRG))")
        }
    }

    /// Verifies that native ECN-2 stocks have negligible halation (due to intact rem-jet during exposure),
    /// whereas CineStill cross-processed stocks exhibit prominent red halation.
    func testRemjetHalationDistinction() throws {
        // Native ECN-2: rem-jet backing absorbs base reflection
        for id in ["vision500t", "vision250d", "eterna500"] {
            let stock = try XCTUnwrap(FilmStock.named(id), "Stock \(id) must load")
            XCTAssertLessThanOrEqual(stock.halationStrength[0], 0.001,
                                     "\(id): native ECN-2 must have negligible red halation (rem-jet)")
            XCTAssertLessThanOrEqual(stock.halationStrength[1], 0.001)
            XCTAssertLessThanOrEqual(stock.halationStrength[2], 0.001)
        }

        // CineStill: rem-jet stripped prior to camera exposure
        for id in ["cinestill800t", "cinestill400d"] {
            let stock = try XCTUnwrap(FilmStock.named(id), "Stock \(id) must load")
            XCTAssertGreaterThanOrEqual(stock.halationStrength[0], 0.10,
                                        "\(id): rem-jet stripped cine stock must exhibit heavy red halation")
        }
    }

    /// Verifies Status M minimum densities (D-min) on native ECN-2 stocks, reflecting the
    /// integral colored masking couplers (Blue > Green > Red Status M density).
    func testECN2StatusMBaseDensitiesAndIntegralMask() throws {
        for id in ["vision500t", "vision250d"] {
            let stock = try XCTUnwrap(FilmStock.named(id), "Stock \(id) must load")
            let redDmin = stock.curves[0].dMin
            let greenDmin = stock.curves[1].dMin
            let blueDmin = stock.curves[2].dMin

            // Masking couplers absorb blue and green: D-min Blue > Green > Red
            XCTAssertGreaterThan(blueDmin, greenDmin, "\(id): Blue D-min must exceed Green D-min")
            XCTAssertGreaterThan(greenDmin, redDmin, "\(id): Green D-min must exceed Red D-min")
            XCTAssertEqual(redDmin, 0.18, accuracy: 0.03, "\(id): Red Status M D-min")
            XCTAssertEqual(greenDmin, 0.58, accuracy: 0.03, "\(id): Green Status M D-min")
            XCTAssertEqual(blueDmin, 0.85, accuracy: 0.03, "\(id): Blue Status M D-min")
        }
    }

    /// Verifies the density-dependent granularity law and Vision3 published profile.
    func testECN2GranularityProfile() throws {
        for id in ["vision500t", "vision250d"] {
            let stock = try XCTUnwrap(FilmStock.named(id), "Stock \(id) must load")
            XCTAssertEqual(stock.grainDensityLaw, .dyeCloud,
                           "\(id): ECN-2 chromogenic negative must obey dye-cloud granularity law")
            XCTAssertEqual(stock.grainDensityProfile.count, 3,
                           "\(id): grain density profile must carry [amplitude, toeDensity, decayDensity]")
            XCTAssertTrue(stock.grainDensityProfile.allSatisfy { $0 > 0 },
                          "\(id): grain density profile entries must be positive")
        }
    }

    /// Verifies that ECN-2 stocks pair with Vision 2383 release print media and correctly
    /// converge to gross Status A LAD aims (1.09, 1.06, 1.03).
    func testECN2PairsWithVision2383ReleasePrint() throws {
        for id in ["vision500t", "vision250d"] {
            let stock = try XCTUnwrap(FilmStock.named(id), "Stock \(id) must load")
            let paper = PrintPaper.vision2383
            let curves = paper.printCurves(for: stock)
            let midpoints = paper.printExposureMidpoints(for: stock)
            let ladAim = try XCTUnwrap(paper.ladStatusA, "Vision 2383 must have LAD aims")

            for channel in 0..<3 {
                let densityAtMidpoint = curves[channel].density(logExposure: midpoints[channel])
                XCTAssertEqual(densityAtMidpoint, ladAim[channel], accuracy: 1e-5,
                               "\(id) on 2383: channel \(channel) must reach exact Status A LAD aim")
            }
        }
    }
}
