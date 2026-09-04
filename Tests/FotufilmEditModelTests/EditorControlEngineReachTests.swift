import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class EditorControlEngineReachTests: XCTestCase {

    private func stock() throws -> FilmStock {
        try XCTUnwrap(FilmStock.presets["example-negative-400"],
                      "the example negative is not installed")
    }

    private func invocation(_ options: FotufilmEngine.Options, _ stock: FilmStock,
                            size: (width: Int, height: Int) = (4000, 2667))
        -> FilmEngineInvocation {
        FilmEngineInvocation(stock: stock, options: options,
                             width: size.width, height: size.height)
    }

    private func instruction(_ invocation: FilmEngineInvocation)
        -> (mask: Int32, configuration: [Float], localTone: Bool) {
        (invocation.featureMask, invocation.configuration,
         invocation.localToneEnabled)
    }

    private func assertReachesTheEngine(
        _ field: EditorControlField,
        on subject: FilmStock? = nil,
        from resting: FotufilmEngine.Options = FotufilmEngine.Options(),
        size: (width: Int, height: Int) = (4000, 2667),
        move: (inout FotufilmEngine.Options) -> Void,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let stock = try subject ?? stock()
        let control = try XCTUnwrap(EditorControlCatalogue.control(field),
                                    "\(field) is not catalogued", file: file,
                                    line: line)
        XCTAssertTrue(control.availability.admits(stock: stock),
                      "\(field) is withheld on the stock this test develops on",
                      file: file, line: line)

        var moved = resting
        move(&moved)
        let before = instruction(invocation(resting, stock, size: size))
        let after = instruction(invocation(moved, stock, size: size))
        XCTAssertTrue(after != before,
                      "\(field) leaves the engine's instruction untouched, so "
                      + "the row is decoration",
                      file: file, line: line)
    }

    private func travel(_ field: EditorControlField) throws -> EditorControlScale {
        let control = try XCTUnwrap(EditorControlCatalogue.control(field))
        guard case .slider(let scale) = control.kind else {
            throw XCTSkip("\(field) is \(control.kind), not a slider")
        }
        return scale
    }

    // MARK: - Grain

    func testMottleReachesTheEngine() throws {
        try assertReachesTheEngine(.grainMottle) { $0.grainMottleShare = 0.9 }
    }

    func testDiscGrainReachesTheEngineWhereAGrainCoversAPixel() throws {
        // On a silver stock, because the disc is the silver model: an opaque grain covers a
        // point or does not, which is what Nutting's relation counts. A chromogenic stock's
        // dye cloud has no opaque area, so the row correctly leaves its instruction alone
        // there — `testDiscGrainIsWithheldFromDyeCloudStocks` is that half.
        let stock = try XCTUnwrap(FilmStock.presets["example-monochrome-100"],
                                  "the example monochrome is not installed")
        XCTAssertEqual(stock.grainDensityLaw, .silver)
        let frameMM: Float = 1.2
        var resting = FotufilmEngine.Options()
        resting.format = FilmFormat(name: "grain bench", frameHeightMM: frameMM)
        let side = Int(frameMM * 2 / stock.grainSizeMM)
        try assertReachesTheEngine(.grainModel, on: stock, from: resting,
                                   size: (side, side)) {
            $0.grainModel = .discs
        }
    }

    func testDiscGrainIsWithheldFromDyeCloudStocks() throws {
        let stock = try stock()
        XCTAssertEqual(stock.grainDensityLaw, .dyeCloud)
        let frameMM: Float = 1.2
        var resting = FotufilmEngine.Options()
        resting.format = FilmFormat(name: "grain bench", frameHeightMM: frameMM)
        let side = Int(frameMM * 2 / stock.grainSizeMM)
        var moved = resting
        moved.grainModel = .discs
        let before = instruction(invocation(resting, stock, size: (side, side)))
        let after = instruction(invocation(moved, stock, size: (side, side)))
        XCTAssertTrue(after == before,
                      "the disc choice reached a dye-cloud stock's instruction")
    }

    func testDiscGrainIsTheClumpFieldWhereAGrainIsSmallerThanAPixel() throws {
        let stock = try stock()
        var discs = FotufilmEngine.Options()
        discs.grainModel = .discs
        XCTAssertLessThan(stock.grainSizeMM * 2667 / 24, 1,
                          "this frame already resolves grains, so the case "
                          + "under test is not the one being measured")
        XCTAssertEqual(
            instruction(invocation(discs, stock)).mask,
            instruction(invocation(FotufilmEngine.Options(), stock)).mask)
    }

    // MARK: - Emulsion

    func testHaloColourReachesTheEngine() throws {
        let colour = Float(try travel(.halationColour).range.upperBound)
        try assertReachesTheEngine(.halationColour) {
            $0.halationSourceColour = colour
        }
    }

    func testTheReturnSpectrumReachesTheEngineAsAColour() throws {
        let stock = try stock()
        let curve = try XCTUnwrap(
            EditorControlCatalogue.control(.halationSpectrum)?.kind.curve)
        var handles = curve.restingValues
        for (index, nm) in curve.handles.enumerated() where nm <= 500 {
            handles[index] = curve.range.upperBound
        }
        let drawn = HalationSpectrum.resampled(handles.map(Float.init))

        try assertReachesTheEngine(.halationSpectrum) {
            $0.halationReturnGain = drawn
        }

        let gain = HalationSpectrum.recordGain(spectrum: drawn,
                                               sensitivity: stock.spectralProfile.layerSensitivity)
        XCTAssertGreaterThan(gain[2], gain[0],
                             "lifting the blue end moved every record alike, so "
                             + "the graph is the amount slider in another shape")
    }

    func testAFlatReturnSpectrumIsNotAnEdit() throws {
        let stock = try stock()
        let curve = try XCTUnwrap(
            EditorControlCatalogue.control(.halationSpectrum)?.kind.curve)
        XCTAssertFalse(curve.isMoved(curve.restingValues))

        var flat = FotufilmEngine.Options()
        flat.halationReturnGain =
            HalationSpectrum.resampled(curve.restingValues.map(Float.init))
        XCTAssertEqual(instruction(invocation(flat, stock)).configuration,
                       instruction(invocation(FotufilmEngine.Options(), stock))
                           .configuration)
    }

    func testSeparationReachesTheEngine() throws {
        let reach = Float(try travel(.couplerReach).range.upperBound)
        try assertReachesTheEngine(.couplerReach) {
            $0.couplerGapReachScales = [reach, reach]
        }
    }

    func testEdgeContrastReachesTheEngineOnItsOwn() throws {
        let scale = Float(try travel(.couplerSelf).range.upperBound)
        try assertReachesTheEngine(.couplerSelf) { $0.couplerSelfScale = scale }

        let stock = try stock()
        var reachOnly = FotufilmEngine.Options()
        reachOnly.couplerGapReachScales = [scale, scale]
        var diagonalOnly = FotufilmEngine.Options()
        diagonalOnly.couplerSelfScale = scale
        XCTAssertNotEqual(invocation(reachOnly, stock).configuration,
                          invocation(diagonalOnly, stock).configuration,
                          "the reach and the diagonal drive the same numbers, "
                          + "so one of the two rows is mislabelled")
    }

    // MARK: - Lab

    func testLongExposureReachesTheEngine() throws {
        try assertReachesTheEngine(.shutter) { $0.shutterSeconds = 30 }
    }

    // MARK: - Light

    func testRegionalKeyingReachesTheEngine() throws {
        var shaped = FotufilmEngine.Options()
        shaped.highlights = -0.6
        shaped.shadows = 0.6
        try assertReachesTheEngine(.localTone, from: shaped) {
            $0.localTone = false
        }
    }

    // MARK: - Print

    func testEncodedGradeReachesTheEngine() throws {
        var graded = FotufilmEngine.Options()
        graded.grade.midtones.level = 0.5
        graded.grade.shadows.balanceX = -0.4
        try assertReachesTheEngine(.gradeSpace, from: graded) {
            $0.gradeSpace = .encoded
        }
    }

    // MARK: - The list this file answers for

    func testEveryNewlySurfacedControlIsCoveredHere() {
        let covered: Set<EditorControlField> = [
            .grainMottle, .grainModel, .couplerReach, .couplerSelf, .shutter,
            .localTone, .gradeSpace,
        ]
        for field in covered {
            XCTAssertNotNil(EditorControlCatalogue.control(field),
                            "\(field) is tested here but no longer catalogued")
        }
        // Each is driven by a control rather than derived or left to a setting, which is the claim
        // the coverage table makes and this file demonstrates.
        let driven = Set(EngineOptionCoverage.byOptionName.values.flatMap {
            if case .control(let fields) = $0 { return fields }
            return []
        })
        XCTAssertTrue(covered.isSubset(of: driven),
                      "\(covered.subtracting(driven)) is tested here but the "
                      + "coverage table says no control drives it")
    }
}
