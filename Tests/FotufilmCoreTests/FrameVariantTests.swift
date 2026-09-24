import XCTest
@testable import FotufilmCore

/// Mirrors the AOT variant table (Sources/FotufilmHalide/aot-variants.json) and the shim's
/// selection rule: a stage bit is covered by any variant that carries it, an exact bit must
/// match. One variant per exact class carries every stage, so what these tests hold is that
/// every request the engine forms lands in a class that exists, on the seam it asked for.
final class FrameVariantTests: XCTestCase {
    private static let allStages =
        FilmEngineFeature.mtf
        | FilmEngineFeature.mtfLuma | FilmEngineFeature.halation
        | FilmEngineFeature.couplers | FilmEngineFeature.couplerDiffusion
        | FilmEngineFeature.adjacency | FilmEngineFeature.grain
        | FilmEngineFeature.printMTF | FilmEngineFeature.diffusion
    private static let fullStages = allStages | FilmEngineFeature.flare
        | FilmEngineFeature.grainMottle | FilmEngineFeature.donorLayer
    private static let densityOut: Int32 = 1 << 13
    private static let densityIn: Int32 = 1 << 14
    private static let flareMeasure: Int32 = 1 << 18
    private static let lightOut: Int32 = 1 << 20
    private static let fieldsIn: Int32 = 1 << 21
    private static let noFilm: Int32 = 1 << 29

    private static let stageBits = fullStages | FilmEngineFeature.crystalGrain
    private static let exactBits = FilmEngineFeature.monochrome | FilmEngineFeature.floatIO
        | FilmEngineFeature.realtime | FilmEngineFeature.exactMath
        | densityOut | densityIn | lightOut | fieldsIn
        | FilmEngineFeature.texture | noFilm
    private static let variantBits = stageBits | exactBits

    private static let realtimeClasses: [Int32] = [
        0, FilmEngineFeature.monochrome,
        densityOut, FilmEngineFeature.monochrome | densityOut,
        densityIn, FilmEngineFeature.monochrome | densityIn,
    ] + [Int32(0), FilmEngineFeature.monochrome].flatMap { mono in
        [Int32(0), FilmEngineFeature.texture, densityOut, densityIn].map {
            mono | FilmEngineFeature.floatIO | FilmEngineFeature.realtime | $0
        }
    }
    private static let stillClasses: [Int32] =
        [Int32(0), FilmEngineFeature.monochrome].flatMap { mono in
            [Int32(0), FilmEngineFeature.exactMath, FilmEngineFeature.texture,
             densityOut, densityIn, fieldsIn].map { mono | FilmEngineFeature.floatIO | $0 }
        }

    private static let exactSeamClasses: [Int32] =
        [Int32(0), FilmEngineFeature.monochrome].flatMap { mono in
            [densityOut, densityIn, lightOut].map {
                mono | FilmEngineFeature.floatIO | FilmEngineFeature.exactMath | $0
            }
        }

    /// The table: every realtime class carries the crystal bit at no cost, every still class has
    /// a crystal twin, the light-out classes compile nothing past the light, and no film is its own.
    private static let variants: [Int32] =
        realtimeClasses.map { fullStages | FilmEngineFeature.crystalGrain | $0 }
        + stillClasses.flatMap { [fullStages | $0, fullStages | FilmEngineFeature.crystalGrain | $0] }
        + [Int32(0), FilmEngineFeature.monochrome].map {
            fullStages | FilmEngineFeature.crystalGrain | FilmEngineFeature.floatIO | lightOut | $0
        }
        + exactSeamClasses.map { fullStages | FilmEngineFeature.crystalGrain | $0 }
        + [FilmEngineFeature.floatIO | noFilm,
           FilmEngineFeature.floatIO | FilmEngineFeature.exactMath | noFilm]

    private func selected(for mask: Int32) -> Int32? {
        Self.variants
            .filter { $0 & Self.exactBits == mask & Self.exactBits && $0 & mask == mask }
            .min { ($0 & ~mask).nonzeroBitCount < ($1 & ~mask).nonzeroBitCount }
    }

    private func masks(width: Int, height: Int,
                       options: FotufilmEngine.Options = FotufilmEngine.Options()
    ) -> [(FilmStock, Int32)] {
        FilmStock.presetIDs.compactMap(FilmStock.named).map { stock in
            let invocation = FilmEngineInvocation(
                stock: stock, options: options, width: width, height: height)
            return (stock, invocation.featureMask & Self.variantBits)
        }
    }

    private static let roads: [(name: String, adds: Int32)] = [
        // The eight-bit surfaces: preview develops and SDR export frames.
        ("processRGBA8", 0),
        // Deep frames on the staged schedule.
        ("processLinearFloat", FilmEngineFeature.floatIO),
        // Deep frames realtime, and the live preview.
        ("processLinearFloat(realtime:)",
         FilmEngineFeature.floatIO | FilmEngineFeature.realtime),
    ]

    @discardableResult
    private func assertServed(
        _ mask: Int32, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Int32? {
        guard let variant = selected(for: mask) else {
            XCTFail("\(label): mask " + String(format: "0x%08x", mask)
                    + " has no compiled variant. Add its class to aot-variants.json (and the "
                    + "mirror in this test).", file: file, line: line)
            return nil
        }
        XCTAssertEqual(variant & Self.exactBits, mask & Self.exactBits,
                       "\(label) resolved to another class", file: file, line: line)
        XCTAssertEqual(variant & mask, mask,
                       "\(label) is served without a stage it asked for", file: file, line: line)
        return variant
    }

    func testEveryClassIsSelectedByItsOwnMask() {
        for variant in Self.variants {
            XCTAssertEqual(selected(for: variant), variant)
        }
    }

    func testPreciseSpatialSeamsPreserveTheirClassForEveryGrainFamily() {
        for seam in Self.exactSeamClasses {
            for grain in [Int32(0), FilmEngineFeature.grain,
                          FilmEngineFeature.grain | FilmEngineFeature.crystalGrain] {
                let mask = seam | grain
                let variant = assertServed(mask, "precise spatial seam with grain mask \(grain)")
                XCTAssertNotNil(variant)
                XCTAssertEqual(variant.map { $0 & Self.exactBits }, seam)
            }
        }
    }

    func testEveryInstalledStockIsServedOnEveryRoad() {
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            for (stock, mask) in masks(width: width, height: height) {
                for road in Self.roads {
                    assertServed(mask | road.adds,
                                 "\(stock.name) at \(width)x\(height) on \(road.name)")
                }
            }
        }
    }

    func testTheGrainMixtureIsServedOnEveryRoadThatAsksForIt() {
        var options = FotufilmEngine.Options()
        options.grainMottleShare = 0.35
        options.grainMottleSizeRatio = 8
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            for (stock, mask) in masks(width: width, height: height, options: options) {
                XCTAssertNotEqual(mask & FilmEngineFeature.grainMottle, 0,
                                  "\(stock.name) never formed the mottle mask")
                for road in Self.roads {
                    assertServed(mask | road.adds,
                                 "\(stock.name) at \(width)x\(height) on \(road.name)")
                }
            }
        }
    }

    func testEverySpanIsCoveredOnBothSchedules() {
        for stage in PipelineStage.allCases {
            var options = FotufilmEngine.Options()
            options.stage = stage
            for (stock, base) in masks(width: 3840, height: 2160, options: options) {
                for realtime in [true, false] {
                    let mask = base | FilmEngineFeature.floatIO
                        | (realtime ? FilmEngineFeature.realtime : 0)
                    assertServed(mask, "\(stock.name) on \(stage.name)"
                                 + (realtime ? " (realtime)" : " (reference)"))
                }
            }
        }
    }

    func testTheDeliveryEncodeAndTheGlareMeasureAreNotPartOfTheClass() {
        let encode: Int32 = (1 << 19) | (1 << 22) | (1 << 23) | (1 << 24)
        XCTAssertEqual((encode | Self.flareMeasure) & Self.variantBits, 0)
        for (stock, mask) in masks(width: 1920, height: 1080) {
            let plain = selected(for: mask | FilmEngineFeature.floatIO)
            let encoded = selected(for: (mask | FilmEngineFeature.floatIO | encode)
                                   & Self.variantBits)
            XCTAssertEqual(plain, encoded, "\(stock.name) changes class to encode its delivery")
            let measured = selected(for: (mask | FilmEngineFeature.floatIO | Self.flareMeasure)
                                    & Self.variantBits)
            XCTAssertEqual(plain, measured, "\(stock.name) changes class to measure its glare")
        }
    }

    func testAnEmptyTextureSelectionIsServed() {
        var options = FotufilmEngine.Options()
        options.stage = .texture
        options.textureStages = .none
        for (stock, base) in masks(width: 3840, height: 2160, options: options) {
            for realtime in [true, false] {
                assertServed(base | FilmEngineFeature.floatIO
                             | (realtime ? FilmEngineFeature.realtime : 0),
                             "\(stock.name) with an empty texture selection")
            }
        }
    }

    func testGrainlessConfigurationsAreCovered() {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        for (stock, mask) in masks(width: 3840, height: 2160, options: options) {
            assertServed(mask | FilmEngineFeature.floatIO, "\(stock.name) with grain off")
        }
    }

    func testEveryGrainModelIsCovered() {
        for model in GrainModel.allCases {
            var options = FotufilmEngine.Options()
            options.grainModel = model
            for (stock, mask) in masks(width: 3840, height: 2160, options: options) {
                // Organic Crystals is the one model with its own family; the film grain model's
                // tiles are a runtime input and ask for no bit.
                XCTAssertEqual(mask & FilmEngineFeature.crystalGrain != 0,
                               model == .crystals && mask & FilmEngineFeature.grain != 0,
                               "\(stock.name) with \(model.title) grain")
                for road in Self.roads {
                    assertServed(mask | road.adds, "\(stock.name) with \(model.title) grain on \(road.name)")
                }
            }
        }
    }

    func testEveryReachableMaskFindsAVariant() {
        let optional = [
            FilmEngineFeature.flare, FilmEngineFeature.mtf,
            FilmEngineFeature.mtfLuma, FilmEngineFeature.halation,
            FilmEngineFeature.couplers, FilmEngineFeature.couplerDiffusion,
            FilmEngineFeature.adjacency, FilmEngineFeature.grain,
            FilmEngineFeature.crystalGrain, FilmEngineFeature.printMTF,
            FilmEngineFeature.diffusion, FilmEngineFeature.donorLayer,
            FilmEngineFeature.grainMottle,
        ]
        for combination in 0..<(1 << optional.count) {
            var mask: Int32 = 0
            for (bit, feature) in optional.enumerated() where combination & (1 << bit) != 0 {
                mask |= feature
            }
            for extra in Self.realtimeClasses + Self.stillClasses {
                assertServed((mask | extra) & Self.variantBits,
                             "mask " + String(format: "0x%08x", mask | extra))
            }
        }
    }
}
