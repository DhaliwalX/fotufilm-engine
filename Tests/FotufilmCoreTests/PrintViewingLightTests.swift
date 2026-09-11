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

    /// A measured neutral is not a flat reflectance, so greys move too — but far less than
    /// colours on this synthetic grid. This is model behavior, not measured print accuracy.
    func testGreysMoveFarLessThanColoursUnderTungsten() {
        let stock = Self.negative
        let d50 = SpectralRuntime.tables(for: stock)
        let tungsten = SpectralRuntime.tables(for: stock, printViewingKelvin: 2856)
        var greyWorst: Float = 0
        for level in stride(from: Float(0), through: 1, by: 0.125) {
            let grey = SIMD3<Float>(repeating: level)
            let a = d50.paperOutput!.sample(grey)
            let b = tungsten.paperOutput!.sample(grey)
            for c in 0..<3 where a[c] > 1e-4 {
                greyWorst = max(greyWorst, abs(b[c] - a[c]) / a[c])
            }
        }
        var colourWorst: Float = 0
        for target in [SIMD3<Float>(0.9, 0.2, 0.2), SIMD3(0.2, 0.9, 0.2),
                       SIMD3(0.2, 0.2, 0.9), SIMD3(0.8, 0.8, 0.2),
                       SIMD3(0.8, 0.2, 0.8), SIMD3(0.2, 0.8, 0.8)] {
            let a = d50.paperOutput!.sample(target)
            let b = tungsten.paperOutput!.sample(target)
            for c in 0..<3 where a[c] > 1e-4 {
                colourWorst = max(colourWorst, abs(b[c] - a[c]) / a[c])
            }
        }
        XCTAssertGreaterThan(greyWorst, 1e-3,
                             "a measured neutral must show some metameric shift")
        XCTAssertLessThan(greyWorst, 0.08)
        XCTAssertGreaterThan(colourWorst / greyWorst, 10,
                             "the grey axis must stay far less metameric than colour")
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

    func testTemperatureCanonicalizationIsBoundedAndIdempotent() {
        for kelvin: Float in [.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertNil(SpectralRuntime.printLightKelvin(kelvin))
        }
        XCTAssertEqual(SpectralRuntime.printLightKelvin(1), 1000)
        XCTAssertEqual(SpectralRuntime.printLightKelvin(.greatestFiniteMagnitude), 25000)
        XCTAssertEqual(SpectralRuntime.printLightKelvin(2920), 2856)
        for kelvin in stride(from: Float(1), through: 26000, by: 1) {
            let canonical = SpectralRuntime.printLightKelvin(kelvin)
            XCTAssertEqual(canonical, SpectralRuntime.printLightKelvin(canonical), "\(kelvin)")
        }
    }

    func testNearbyTemperaturesDoNotDependOnRequestOrder() {
        var firstStock = Self.negative
        firstStock.referenceIlluminantKelvin = 5531
        var secondStock = firstStock
        secondStock.referenceIlluminantKelvin = 5532
        let a = SpectralRuntime.tables(for: firstStock, paper: .vision2383, printViewingKelvin: 2920)
        let b = SpectralRuntime.tables(for: firstStock, paper: .vision2383, printViewingKelvin: 2856)
        let c = SpectralRuntime.tables(for: secondStock, paper: .vision2383, printViewingKelvin: 2856)
        let d = SpectralRuntime.tables(for: secondStock, paper: .vision2383, printViewingKelvin: 2920)
        XCTAssertEqual(a.paperOutput?.values, b.paperOutput?.values)
        XCTAssertEqual(c.paperOutput?.values, d.paperOutput?.values)
        XCTAssertEqual(a.paperOutput?.values, c.paperOutput?.values)
        for stock in [firstStock, secondStock] {
            XCTAssertEqual(SpectralRuntime.cacheIdentifier(for: stock, printViewingKelvin: 2920),
                           SpectralRuntime.cacheIdentifier(for: stock, printViewingKelvin: 2856))
        }
    }

    func testExtremeInputCannotPoisonReferenceTables() {
        var stock = Self.negative
        stock.referenceIlluminantKelvin = 5533
        let low = SpectralRuntime.tables(for: stock, paper: .vision2383, printViewingKelvin: 1)
        let reference = SpectralRuntime.tables(for: stock, paper: .vision2383)
        let high = SpectralRuntime.tables(for: stock, paper: .vision2383,
                                          printViewingKelvin: .greatestFiniteMagnitude)
        for tables in [low, reference, high] {
            XCTAssertTrue(tables.paperOutput!.values.allSatisfy(\.isFinite))
        }
        XCTAssertNotEqual(low.paperOutput?.values, reference.paperOutput?.values)
        XCTAssertNotEqual(SpectralRuntime.cacheIdentifier(for: stock, printViewingKelvin: 1),
                          SpectralRuntime.cacheIdentifier(for: stock))
    }

    func testViewingOnlyChangesLightNotDevelopedDyesOrPrinting() {
        let stock = Self.negative
        for paper in PrintPaper.allCases where paper.acceptsViewingIlluminant {
            let reference = SpectralRuntime.tables(for: stock, paper: paper)
            let warm = SpectralRuntime.tables(for: stock, paper: paper, printViewingKelvin: 2856)
            XCTAssertEqual(reference.filmOutput.values, warm.filmOutput.values)
            for light in [Illuminant.a, Illuminant.d50, Illuminant.d65, Illuminant.xenonProjection] {
                let receiver = SpectralRuntime.printReceiver(stock: stock, paper: paper, viewingLight: light)
                for amounts in [SIMD3<Float>(1, 1, 1), SIMD3(0.3, 1.2, 0.5), SIMD3(1.1, 0.4, 0.8)] {
                    let density = Densitometry.statusADensity(amounts: amounts, dyes: paper.analyticalDyes)
                    let actual = receiver.rgb(density: density)
                    let expected = SpectralRuntime.transmissionRGB(
                        density: [amounts.x, amounts.y, amounts.z], dyes: paper.analyticalDyes,
                        flare: paper.viewingFlare, illuminant: light)
                    for channel in 0..<3 {
                        XCTAssertEqual(actual[channel], expected[channel], accuracy: 2e-5,
                                       "\(paper): a viewing lamp must not retime dye")
                    }
                }
            }
        }
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
