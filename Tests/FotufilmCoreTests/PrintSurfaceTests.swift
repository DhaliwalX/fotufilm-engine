import XCTest
@testable import FotufilmCore

final class PrintSurfaceTests: XCTestCase {
    func testCleanSurfacePreservesExistingCacheIdentityAndTables() throws {
        let negative = try XCTUnwrap(FilmStock.named("portra400"))
        let reversal = try XCTUnwrap(FilmStock.named("ektachromee100"))
        let monochrome = try XCTUnwrap(FilmStock.named("trix400"))

        for (stock, paper) in [(negative, PrintPaper.ektacolorEdge),
                               (negative, PrintPaper.enduraPremier),
                               (negative, PrintPaper.crystalArchive),
                               (negative, PrintPaper.vision2383),
                               (negative, PrintPaper.screen),
                               (reversal, PrintPaper.ilfochromeCPS1K),
                               (monochrome, PrintPaper.ektacolorEdge)] {
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper),
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper, printSurface: .clean),
                "\(stock.name) on \(paper.id)")
            let clean = SpectralRuntime.tables(for: stock, paper: paper, printSurface: .clean)
            let baseline = SpectralRuntime.tables(for: stock, paper: paper)
            XCTAssertEqual(clean.paperOutput?.values, baseline.paperOutput?.values)
        }
    }

    func testNonReflectionMediaIgnorePrintSurfaceCompletely() throws {
        let negative = try XCTUnwrap(FilmStock.named("vision250d"))
        let reversal = try XCTUnwrap(FilmStock.named("ektachromee100"))

        for (stock, paper) in [(negative, PrintPaper.vision2383),
                               (negative, PrintPaper.screen),
                               (negative, PrintPaper.labScan),
                               (negative, PrintPaper.telecine),
                               (negative, PrintPaper.cineonLog),
                               (negative, PrintPaper.negative),
                               (reversal, PrintPaper.screen)] {
            XCTAssertFalse(PrintSurface.applies(stock: stock, paper: paper),
                           "\(paper.id) should not take a reflection surface")
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper, printSurface: .clean),
                SpectralRuntime.cacheIdentifier(for: stock, paper: paper, printSurface: .matte),
                "\(paper.id) cache key must ignore PrintSurface")
        }
    }

    func testSurfaceFinishesOrderShadowDensityMonotonically() throws {
        let stock = try XCTUnwrap(FilmStock.named("portra400"))
        let monochrome = try XCTUnwrap(FilmStock.named("trix400"))

        for film in [stock, monochrome] {
            let stops: [Float] = [-6, -4, 0, 4]
            let clean = SpectralRuntime.neutralToneScale(
                stops: stops, stock: film, paper: .ektacolorEdge, printCorrection: 0,
                printSurface: .clean)
            let glossy = SpectralRuntime.neutralToneScale(
                stops: stops, stock: film, paper: .ektacolorEdge, printCorrection: 0,
                printSurface: .glossy)
            let lustre = SpectralRuntime.neutralToneScale(
                stops: stops, stock: film, paper: .ektacolorEdge, printCorrection: 0,
                printSurface: .lustre)
            let matte = SpectralRuntime.neutralToneScale(
                stops: stops, stock: film, paper: .ektacolorEdge, printCorrection: 0,
                printSurface: .matte)

            // Deep shadows (-6 EV) lift monotonically with diffuse surface scatter.
            XCTAssertLessThan(clean[0], glossy[0])
            XCTAssertLessThan(glossy[0], lustre[0])
            XCTAssertLessThan(lustre[0], matte[0])

            // Paper highlights (+4 EV) reflect natural paper whiteness (< 1.0) on physical finishes.
            XCTAssertLessThan(glossy[3], clean[3])
            XCTAssertGreaterThan(glossy[3], 0.80)
        }
    }

    func testPaperStocksExhibitDistinctBaseTintsOnPhysicalFinishes() throws {
        let stock = try XCTUnwrap(FilmStock.named("portra400"))
        let enduraReceiver = SpectralRuntime.printReceiver(
            stock: stock, paper: .enduraPremier, viewingLight: Illuminant.d50,
            printSurface: .glossy)
        let crystalReceiver = SpectralRuntime.printReceiver(
            stock: stock, paper: .crystalArchive, viewingLight: Illuminant.d50,
            printSurface: .glossy)
        let edgeReceiver = SpectralRuntime.printReceiver(
            stock: stock, paper: .ektacolorEdge, viewingLight: Illuminant.d50,
            printSurface: .glossy)

        let enduraWhite = enduraReceiver.rgb(density: .zero)
        let edgeWhite = edgeReceiver.rgb(density: .zero)
        let crystalWhite = crystalReceiver.rgb(density: .zero)

        // Crystal Archive's optical brightener lifts blue/red relative to Ektacolor Edge,
        // while Endura Premier's portrait base stays warmer than Ektacolor Edge.
        let enduraBlueOverRed = enduraWhite.z / enduraWhite.x
        let edgeBlueOverRed = edgeWhite.z / edgeWhite.x
        let crystalBlueOverRed = crystalWhite.z / crystalWhite.x

        XCTAssertLessThan(enduraBlueOverRed, edgeBlueOverRed)
        XCTAssertLessThan(edgeBlueOverRed, crystalBlueOverRed)

        // Frame border white matches clear paper white on the selected surface.
        let framed = PrintFrameConfiguration(
            frame: .paper, formatID: "135", stockID: "portra400",
            paper: .crystalArchive, printSurface: .glossy)
        XCTAssertEqual(framed.baseRGB.x, crystalWhite.x, accuracy: 1e-6)
        XCTAssertEqual(framed.baseRGB.y, crystalWhite.y, accuracy: 1e-6)
        XCTAssertEqual(framed.baseRGB.z, crystalWhite.z, accuracy: 1e-6)
    }
}
