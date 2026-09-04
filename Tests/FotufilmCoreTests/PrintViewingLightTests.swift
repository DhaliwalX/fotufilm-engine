import XCTest
@testable import FotufilmCore

/// The print-viewing illuminant: the finished sheet read under a stated lamp through Bradford
/// chromatic adaptation to the renderer's D65 display white.
final class PrintViewingLightTests: XCTestCase {

    private static var negative: FilmStock {
        FilmStock.presets["example-negative-400"]!
    }

    func testOffPositionKeepsEveryCacheIdentity() {
        for stock in FilmStock.presets.values {
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: stock),
                SpectralRuntime.cacheIdentifier(for: stock, printViewingKelvin: nil),
                stock.name)
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: stock),
                SpectralRuntime.cacheIdentifier(for: stock, printViewingKelvin: -1),
                stock.name)
        }
    }

    func testReversalIgnoresTheLamp() {
        for stock in FilmStock.presets.values where stock.isReversal {
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: stock),
                SpectralRuntime.cacheIdentifier(for: stock, printViewingKelvin: 2856),
                stock.name)
        }
    }

    func testGreysHoldUnderTungsten(){
        let stock = Self.negative
        let d50 = SpectralRuntime.tables(for: stock)
        let tungsten = SpectralRuntime.tables(for: stock, printViewingKelvin: 2856)
        for level in stride(from: Float(0), through: 1, by: 0.125) {
            let grey = SIMD3<Float>(repeating: level)
            let a = d50.paperOutput!.sample(grey)
            let b = tungsten.paperOutput!.sample(grey)
            for c in 0..<3 {
                XCTAssertEqual(b[c], a[c], accuracy: max(a[c] * 1.5e-2, 1e-5),
                               "level \(level) channel \(c)")
            }
        }
    }

    /// What must move: an unequal density triple — a colour — reads differently once
    /// the lamp changes, because the paper dyes' unwanted absorptions weigh differently
    /// against a red-heavy SPD.
    func testColoursMoveByMetamerism() {
        let stock = Self.negative
        let d50 = SpectralRuntime.tables(for: stock)
        let tungsten = SpectralRuntime.tables(for: stock, printViewingKelvin: 2856)
        // A print cyan patch: heavy cyan-dye activation, light in the others.
        let cyanish = SIMD3<Float>(0.7, 0.3, 0.2)
        let a = d50.paperOutput!.sample(cyanish)
        let b = tungsten.paperOutput!.sample(cyanish)
        let delta = a - b
        let shift = (delta * delta).sum().squareRoot()
        XCTAssertGreaterThan(shift, 0.005)
    }

    func testGateBuckets() {
        XCTAssertNil(SpectralRuntime.printLightKelvin(nil))
        XCTAssertNil(SpectralRuntime.printLightKelvin(0))
        XCTAssertEqual(SpectralRuntime.printLightKelvin(2856), 2856)
        XCTAssertEqual(SpectralRuntime.printLightKelvin(5003), 5003)
        XCTAssertEqual(SpectralRuntime.printLightKelvin(6504), 6504)
        XCTAssertEqual(SpectralRuntime.printLightKelvin(5432), 5400)
    }

    func testBradfordAdaptationKeepsAFlatReflectorNeutral() {
        let reflectance = [Float](repeating: 0.37, count: SpectralGrid.count)
        for illuminant in [Illuminant.a, Illuminant.d50, Illuminant.d65,
                           Illuminant.xenonProjection] {
            let rgb = SpectralGrid.toLinearDisplayP3(reflectance: reflectance,
                                                     under: illuminant)
            XCTAssertEqual(rgb.x, 0.37, accuracy: 2e-5)
            XCTAssertEqual(rgb.y, 0.37, accuracy: 2e-5)
            XCTAssertEqual(rgb.z, 0.37, accuracy: 2e-5)
        }
    }

    func testScreenAndScansIgnoreAViewingIlluminant() {
        let stock = Self.negative
        for paper: PrintPaper in [.screen, .labScan, .telecine, .negative] {
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper),
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper,
                                                printViewingKelvin: 2856),
                paper.rawValue)
        }
    }
}
