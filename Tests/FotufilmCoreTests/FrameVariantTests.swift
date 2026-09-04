import XCTest
@testable import FotufilmCore

final class FrameVariantTests: XCTestCase {
    private static let allStages =
        FilmEngineFeature.mtf
        | FilmEngineFeature.mtfLuma | FilmEngineFeature.halation
        | FilmEngineFeature.couplers | FilmEngineFeature.couplerDiffusion
        | FilmEngineFeature.adjacency | FilmEngineFeature.grain
        | FilmEngineFeature.printMTF | FilmEngineFeature.diffusion
    private static let head =
        allStages & ~(FilmEngineFeature.grain | FilmEngineFeature.printMTF)
    private static let negative =
        FilmEngineFeature.mtf
        | FilmEngineFeature.halation | FilmEngineFeature.couplers
        | FilmEngineFeature.couplerDiffusion | FilmEngineFeature.adjacency
        | FilmEngineFeature.grain
    private static let slide =
        FilmEngineFeature.mtf
        | FilmEngineFeature.halation | FilmEngineFeature.adjacency
        | FilmEngineFeature.grain
    private static let slideInterimage = slide | FilmEngineFeature.couplers
    private static let slideNoMTF = slide & ~FilmEngineFeature.mtf
    private static let densityOut: Int32 = 1 << 13
    private static let densityIn: Int32 = 1 << 14
    private static let tail =
        FilmEngineFeature.grain | FilmEngineFeature.printMTF | densityIn
    private static let negativeSpan = (allStages & ~FilmEngineFeature.printMTF) | densityOut
    private static let printSpan = FilmEngineFeature.printMTF | densityIn
    private static let textureSpan = allStages | FilmEngineFeature.texture
    private static let textureFlatSpan =
        FilmEngineFeature.flare | FilmEngineFeature.couplers | FilmEngineFeature.texture

    private static func enlarged(_ mask: Int32) -> Int32 {
        mask | FilmEngineFeature.printMTF
    }

    private static func donor(_ mask: Int32) -> Int32 {
        mask | FilmEngineFeature.donorLayer
    }

    private static func mottle(_ mask: Int32) -> Int32 {
        mask | FilmEngineFeature.grainMottle
    }

    private static let variantBits =
        allStages | FilmEngineFeature.grainMottle | FilmEngineFeature.flare
        | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
        | FilmEngineFeature.realtime | FilmEngineFeature.exactMath
        | densityOut | densityIn | FilmEngineFeature.discGrain
        | FilmEngineFeature.texture | FilmEngineFeature.donorLayer

    private static let variants: [Int32] = [
        allStages,
        allStages | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.monochrome,
        allStages | FilmEngineFeature.monochrome | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.floatIO,
        allStages | FilmEngineFeature.floatIO | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO,
        allStages | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.floatIO | FilmEngineFeature.exactMath,
        allStages | FilmEngineFeature.floatIO | FilmEngineFeature.exactMath
            | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.exactMath,
        allStages | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.exactMath | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.floatIO | FilmEngineFeature.realtime,
        allStages | FilmEngineFeature.floatIO | FilmEngineFeature.realtime
            | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.realtime,
        allStages | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.realtime | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.flare,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome
            | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO
            | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome
            | FilmEngineFeature.floatIO,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome
            | FilmEngineFeature.floatIO | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO
            | FilmEngineFeature.realtime,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO
            | FilmEngineFeature.realtime | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome
            | FilmEngineFeature.floatIO | FilmEngineFeature.realtime,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome
            | FilmEngineFeature.floatIO | FilmEngineFeature.realtime
            | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO
            | FilmEngineFeature.exactMath,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO
            | FilmEngineFeature.exactMath | FilmEngineFeature.discGrain,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome
            | FilmEngineFeature.floatIO | FilmEngineFeature.exactMath,
        allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome
            | FilmEngineFeature.floatIO | FilmEngineFeature.exactMath
            | FilmEngineFeature.discGrain,
        enlarged(negative),
        enlarged(negative | FilmEngineFeature.discGrain),
        enlarged(negative & ~FilmEngineFeature.grain),
        enlarged(negative | FilmEngineFeature.mtfLuma),
        enlarged((negative & ~FilmEngineFeature.adjacency) | FilmEngineFeature.mtfLuma),
        enlarged((negative & ~FilmEngineFeature.grain) | FilmEngineFeature.mtfLuma),
        enlarged((negative & ~(FilmEngineFeature.adjacency | FilmEngineFeature.grain))
                 | FilmEngineFeature.mtfLuma),
        slide,
        slide | FilmEngineFeature.discGrain,
        slide & ~FilmEngineFeature.grain,
        slideInterimage,
        slideInterimage & ~FilmEngineFeature.grain,
        slide | FilmEngineFeature.mtfLuma,
        (slide & ~FilmEngineFeature.adjacency) | FilmEngineFeature.mtfLuma,
        (slide & ~FilmEngineFeature.grain) | FilmEngineFeature.mtfLuma,
        (slide & ~(FilmEngineFeature.adjacency | FilmEngineFeature.grain))
            | FilmEngineFeature.mtfLuma,
        enlarged(slide | FilmEngineFeature.monochrome),
        enlarged(slide | FilmEngineFeature.monochrome
                 | FilmEngineFeature.discGrain),
        enlarged((slide & ~FilmEngineFeature.grain)
                 | FilmEngineFeature.monochrome),
        enlarged(slide | FilmEngineFeature.monochrome | FilmEngineFeature.mtfLuma),
        enlarged(slide | FilmEngineFeature.monochrome | FilmEngineFeature.mtfLuma
                 | FilmEngineFeature.discGrain),
        enlarged((slide & ~FilmEngineFeature.adjacency)
                 | FilmEngineFeature.monochrome | FilmEngineFeature.mtfLuma),
        enlarged((slide & ~FilmEngineFeature.grain)
                 | FilmEngineFeature.monochrome | FilmEngineFeature.mtfLuma),
        enlarged((slide & ~(FilmEngineFeature.adjacency | FilmEngineFeature.grain))
                 | FilmEngineFeature.monochrome | FilmEngineFeature.mtfLuma),
        enlarged(slideNoMTF | FilmEngineFeature.monochrome),
        enlarged(slideNoMTF | FilmEngineFeature.monochrome
                 | FilmEngineFeature.discGrain),
        enlarged((slideNoMTF & ~FilmEngineFeature.grain)
                 | FilmEngineFeature.monochrome),
        head | densityOut,
        head | densityOut | FilmEngineFeature.monochrome,
        tail,
        tail | FilmEngineFeature.discGrain,
        tail | FilmEngineFeature.monochrome,
        tail | FilmEngineFeature.monochrome | FilmEngineFeature.discGrain,
        negativeSpan | FilmEngineFeature.floatIO | FilmEngineFeature.realtime,
        negativeSpan | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.realtime,
        printSpan | FilmEngineFeature.floatIO | FilmEngineFeature.realtime,
        printSpan | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.realtime,
        textureSpan | FilmEngineFeature.floatIO | FilmEngineFeature.realtime,
        textureSpan | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.realtime,
        negativeSpan | FilmEngineFeature.floatIO,
        negativeSpan | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO,
        printSpan | FilmEngineFeature.floatIO,
        printSpan | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO,
        textureSpan | FilmEngineFeature.floatIO,
        textureSpan | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO,
        textureFlatSpan | FilmEngineFeature.floatIO | FilmEngineFeature.realtime,
        textureFlatSpan | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.realtime,
        textureFlatSpan | FilmEngineFeature.floatIO,
        textureFlatSpan | FilmEngineFeature.monochrome | FilmEngineFeature.floatIO,
        // The `_donor` twins, mirroring FOTUFILM_AOT_DONOR. Colour only: a monochrome stock
        // coats no 4th Color Layer, and FilmEngineInvocation refuses the bit for one, so the
        // AOT set carries no monochrome twin either. The encode, measure and fields families
        // have twins in the header that are absent here only because their *bases* are — this
        // mirror has never carried those bits.
        donor(allStages),
        donor(allStages | FilmEngineFeature.floatIO),
        donor(allStages | FilmEngineFeature.floatIO | FilmEngineFeature.exactMath),
        donor(allStages | FilmEngineFeature.floatIO | FilmEngineFeature.realtime),
        donor(allStages | FilmEngineFeature.flare),
        donor(allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO),
        donor(allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO
              | FilmEngineFeature.realtime),
        donor(allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO
              | FilmEngineFeature.exactMath),
        donor(enlarged(negative)),
        donor(enlarged(negative & ~FilmEngineFeature.grain)),
        donor(enlarged(negative | FilmEngineFeature.mtfLuma)),
        donor(enlarged((negative & ~FilmEngineFeature.adjacency)
                       | FilmEngineFeature.mtfLuma)),
        donor(enlarged((negative & ~FilmEngineFeature.grain)
                       | FilmEngineFeature.mtfLuma)),
        donor(enlarged((negative
                        & ~(FilmEngineFeature.adjacency | FilmEngineFeature.grain))
                       | FilmEngineFeature.mtfLuma)),
        donor(head | densityOut),
        donor(negativeSpan | FilmEngineFeature.floatIO | FilmEngineFeature.realtime),
        donor(negativeSpan | FilmEngineFeature.floatIO),
        donor(textureSpan | FilmEngineFeature.floatIO | FilmEngineFeature.realtime),
        donor(textureSpan | FilmEngineFeature.floatIO),
        donor(textureFlatSpan | FilmEngineFeature.floatIO | FilmEngineFeature.realtime),
        donor(textureFlatSpan | FilmEngineFeature.floatIO),
        // The `_mottle` twins, mirroring FOTUFILM_AOT_MOTTLE: an explicit grain-size mixture.
        // Each carries every superset-able stage — flare, and the donor layer on the colour arm
        // — so these entries serve the path's whole mask family; the encode and measure twins
        // are absent here for the same reason the donor family's are, their bases never appear
        // in this mirror.
        //
        // The plain and float-only pairs are the ones the family first shipped without, and
        // they are the ones that mattered: FLOAT_IO and REALTIME are both exact bits, so the
        // 8-bit path every SDR video frame takes was served by nothing at all.
        mottle(donor(allStages | FilmEngineFeature.flare)),
        mottle(allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome),
        mottle(donor(allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO)),
        mottle(allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome
               | FilmEngineFeature.floatIO),
        mottle(donor(allStages | FilmEngineFeature.flare | FilmEngineFeature.floatIO
                     | FilmEngineFeature.realtime)),
        mottle(allStages | FilmEngineFeature.flare | FilmEngineFeature.monochrome
               | FilmEngineFeature.floatIO | FilmEngineFeature.realtime),
        // The split recording path's tail carries the mixture bit through, so the tail
        // span has its own twins.
        mottle(tail),
        mottle(tail | FilmEngineFeature.monochrome),
    ]

    private func selected(for mask: Int32) -> Int32? {
        let exact = FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
            | FilmEngineFeature.realtime | FilmEngineFeature.exactMath
            | Self.densityOut | Self.densityIn | FilmEngineFeature.texture
        return Self.variants
            .filter { $0 & exact == mask & exact && $0 & mask == mask }
            .min { ($0 & ~mask).nonzeroBitCount < ($1 & ~mask).nonzeroBitCount }
    }

    private func masks(width: Int, height: Int) -> [(FilmStock, Int32)] {
        FilmStock.presetIDs.compactMap(FilmStock.named).map { stock in
            let invocation = FilmEngineInvocation(
                stock: stock, options: FotufilmEngine.Options(),
                width: width, height: height)
            return (stock, invocation.featureMask & Self.variantBits)
        }
    }

    private static let permittedExcess = FilmEngineFeature.printMTF
        | FilmEngineFeature.diffusion

    private func assertVariantIsTight(
        _ mask: Int32, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let variant = selected(for: mask) else {
            XCTFail("\(label): mask " + String(format: "0x%05x", mask)
                    + " has no compiled variant at all", file: file, line: line)
            return
        }
        XCTAssertEqual(
            variant & ~Self.permittedExcess, mask & ~Self.permittedExcess,
            "\(label) asks for mask " + String(format: "0x%05x", mask)
            + " and would fall back to " + String(format: "0x%05x", variant)
            + ", running stages it does not use. Add its mask to "
            + "FOTUFILM_AOT_VARIANTS in FotufilmHalide.h (and the mirror in "
            + "this test).", file: file, line: line)
    }

    func testEveryInstalledStockHasItsOwnVariant() {
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            for (stock, mask) in masks(width: width, height: height) {
                assertVariantIsTight(mask, "\(stock.name) at \(width)x\(height)")
            }
        }
    }

    private static let mottleRoads: [(name: String, adds: Int32)] = [
        // The eight-bit surfaces: preview develops and SDR export frames.
        ("processRGBA8", 0),
        // Deep frames on the staged schedule.
        ("processLinearFloat", FilmEngineFeature.floatIO),
        // Deep frames realtime, and the live preview.
        ("processLinearFloat(realtime:)",
         FilmEngineFeature.floatIO | FilmEngineFeature.realtime),
    ]

    func testTheGrainMixtureIsServedOnEveryRoadThatAsksForIt() {
        var options = FotufilmEngine.Options()
        options.grainMottleShare = 0.35
        options.grainMottleSizeRatio = 8
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            for stock in FilmStock.presetIDs.compactMap(FilmStock.named) {
                let invocation = FilmEngineInvocation(
                    stock: stock, options: options, width: width, height: height)
                XCTAssertNotEqual(
                    invocation.featureMask & FilmEngineFeature.grainMottle, 0,
                    "\(stock.name) never formed the mottle mask")
                for road in Self.mottleRoads {
                    let mask = (invocation.featureMask & Self.variantBits) | road.adds
                    let where_ = "\(stock.name) at \(width)x\(height) on \(road.name)"
                    guard let variant = selected(for: mask) else {
                        XCTFail("\(where_): no variant serves "
                                + String(format: "0x%08x", mask))
                        continue
                    }
                    XCTAssertNotEqual(
                        variant & FilmEngineFeature.grainMottle, 0,
                        "\(where_) would be served without the mixture — quieter grain, "
                        + "not merely uncoarsened")
                }
            }
        }
    }


    func testNoStockIsPrintedWithoutItsEnlarger() {
        var printed = 0
        for (stock, mask) in masks(width: 3840, height: 2160) {
            guard mask & FilmEngineFeature.printMTF != 0 else { continue }
            printed += 1
            guard let variant = selected(for: mask) else {
                XCTFail("\(stock.name) has no variant")
                continue
            }
            XCTAssertNotEqual(
                variant & FilmEngineFeature.printMTF, 0,
                "\(stock.name) is printed but would run a variant with no "
                + "enlarger compiled in")
        }
        XCTAssertGreaterThan(printed, 0, "no installed stock is printed at all")
    }

    func testEverySpanIsCoveredOnBothSchedules() {
        for stage in PipelineStage.allCases {
            var options = FotufilmEngine.Options()
            options.stage = stage
            for stock in FilmStock.presetIDs.compactMap(FilmStock.named) {
                let base = FilmEngineInvocation(
                    stock: stock, options: options, width: 3840, height: 2160).featureMask
                for realtime in [true, false] {
                    let mask = (base | FilmEngineFeature.floatIO
                                | (realtime ? FilmEngineFeature.realtime : 0))
                        & Self.variantBits
                    let label = "\(stock.name) on \(stage.name)"
                        + (realtime ? " (realtime)" : " (reference)")
                    guard let variant = selected(for: mask) else {
                        XCTFail(label + " asks for mask " + String(format: "0x%06x", mask)
                                + " and has no compiled variant at all. Add it to "
                                + "FOTUFILM_AOT_VARIANTS in FotufilmHalide.h (and the mirror "
                                + "in this test).")
                        continue
                    }
                    let seams = Self.densityOut | Self.densityIn | FilmEngineFeature.texture
                    XCTAssertEqual(variant & seams, mask & seams,
                                   label + " resolved across the seam")
                }
            }
        }
    }

    func testSpanBitsAreMatchedExactlyRatherThanCovered() {
        let seams = [Self.densityOut, Self.densityIn, FilmEngineFeature.texture]
        for variant in Self.variants {
            for seam in seams {
                guard variant & seam != 0 else { continue }
                XCTAssertEqual(
                    selected(for: variant)! & seam, seam,
                    "a variant carrying " + String(format: "0x%05x", seam)
                    + " resolved to one without it")
            }
            // And the other way: a request with no seam bit must never land on a variant with one.
            for seam in seams {
                let plain = variant & ~seam
                guard plain != variant, let chosen = selected(for: plain) else { continue }
                XCTAssertEqual(chosen & seam, 0,
                               "a request without " + String(format: "0x%05x", seam)
                               + " resolved to a variant carrying it")
            }
        }
    }

    func testAnEmptyTextureSelectionIsServedWithoutASpareStage() {
        var options = FotufilmEngine.Options()
        options.stage = .texture
        options.textureStages = .none
        for stock in FilmStock.presetIDs.compactMap(FilmStock.named) {
            let base = FilmEngineInvocation(
                stock: stock, options: options, width: 3840, height: 2160).featureMask
            for realtime in [true, false] {
                let mask = (base | FilmEngineFeature.floatIO
                            | (realtime ? FilmEngineFeature.realtime : 0)) & Self.variantBits
                guard let variant = selected(for: mask) else {
                    XCTFail("\(stock.name) has no empty-selection texture variant")
                    continue
                }
                XCTAssertEqual(
                    variant & Self.allStages & ~FilmEngineFeature.flare
                        & ~FilmEngineFeature.couplers, 0,
                    "\(stock.name) would run its texture span through a variant carrying "
                    + String(format: "0x%06x", variant & Self.allStages)
                    + ", and a spare spatial stage there is not free")
            }
        }
    }

    func testGrainlessConfigurationsAreCovered() {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        for stock in FilmStock.presetIDs.compactMap(FilmStock.named) {
            let invocation = FilmEngineInvocation(
                stock: stock, options: options, width: 3840, height: 2160)
            let mask = invocation.featureMask & Self.variantBits
            assertVariantIsTight(mask, "\(stock.name) with grain off")
        }
    }

    func testResolvedDiscConfigurationsAreCovered() {
        var options = FotufilmEngine.Options()
        options.grainModel = .discs
        options.format = FilmFormat(name: "resolved grain", frameHeightMM: 1.2)
        for stock in FilmStock.presetIDs.compactMap(FilmStock.named) {
            let invocation = FilmEngineInvocation(
                stock: stock, options: options, width: 3840, height: 2160)
            let mask = invocation.featureMask & Self.variantBits
            // An opaque disc is a silver model. A chromogenic stock forms dye clouds and
            // renders the clump field however far the frame is enlarged, so it is the
            // silver stocks that have to reach the disc variant, and the others that have
            // to stay off it.
            guard stock.grainDensityLaw == .silver else {
                XCTAssertEqual(mask & FilmEngineFeature.discGrain, 0,
                               "\(stock.name) forms dye clouds and must not render discs")
                continue
            }
            guard mask & FilmEngineFeature.grain == 0
                    || mask & FilmEngineFeature.discGrain != 0 else {
                XCTFail("\(stock.name) did not activate resolved disc grain")
                continue
            }
            assertVariantIsTight(mask, "\(stock.name) with disc grain")
        }
    }

    func testEveryReachableMaskFindsAVariant() {
        let optional = [
            FilmEngineFeature.flare, FilmEngineFeature.mtf,
            FilmEngineFeature.mtfLuma, FilmEngineFeature.halation,
            FilmEngineFeature.couplers, FilmEngineFeature.couplerDiffusion,
            FilmEngineFeature.adjacency, FilmEngineFeature.grain,
            FilmEngineFeature.discGrain, FilmEngineFeature.printMTF,
            // The lens diffusion filter, carried by the full variants since it joined
            // FOTUFILM_AOT_ALL_STAGES; a request that wants it has to land on one of those.
            FilmEngineFeature.diffusion,
            // The 4th Color Layer. In the allow-list rather than outside it, because the
            // stage's counterweight lives in the warp table: a request that carries the bit
            // and is served without the stage is not slower, it is red.
            FilmEngineFeature.donorLayer,
        ]
        for combination in 0..<(1 << optional.count) {
            var mask: Int32 = 0
            for (bit, feature) in optional.enumerated() where combination & (1 << bit) != 0 {
                mask |= feature
            }
            for extra in [Int32(0), FilmEngineFeature.monochrome,
                          FilmEngineFeature.floatIO,
                          FilmEngineFeature.monochrome | FilmEngineFeature.floatIO,
                          FilmEngineFeature.floatIO | FilmEngineFeature.realtime,
                          FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
                              | FilmEngineFeature.realtime,
                          FilmEngineFeature.floatIO | FilmEngineFeature.exactMath,
                          FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
                              | FilmEngineFeature.exactMath] {
                // Through the same narrowing the AOT shim performs before it selects
                // (`feature_mask & FOTUFILM_AOT_VARIANT_BITS`, FotufilmHalideIOS.cpp). A bit
                // outside the allow-list — the grain mottle's, say — is dropped here and the
                // frame falls back to the nearest variant without it. Selecting on the raw
                // mask instead would demand a variant that contains every bit, which is a
                // stricter rule than the device's and fails on stages that are deliberately
                // outside the AOT set.
                let full = (mask | extra) & Self.variantBits
                // The two pairings FilmEngineInvocation refuses to form. A 4th Color Layer
                // modulates dye formation between colour records, so it belongs to a
                // chromogenic colour emulsion: a monochrome record has no colour to
                // inter-image with, and the disc model is for an opaque-silver image rather
                // than a dye cloud. Neither mask is reachable, so the AOT set carries no twin.
                if full & FilmEngineFeature.donorLayer != 0,
                   full & (FilmEngineFeature.monochrome
                           | FilmEngineFeature.discGrain) != 0 { continue }
                guard let variant = selected(for: full) else {
                    XCTFail("mask " + String(format: "0x%03x", full)
                            + " has no variant to fall back to")
                    continue
                }
                XCTAssertEqual(variant & full, full,
                               "fallback for " + String(format: "0x%03x", full)
                               + " is missing a stage it asked for")
            }
        }
    }
}
