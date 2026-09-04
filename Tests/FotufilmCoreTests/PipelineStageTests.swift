import XCTest
@testable import FotufilmCore

final class PipelineStageTests: XCTestCase {
    private func scene(width: Int = 48, height: Int = 32) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let ramp = Float(x) / Float(width - 1)
                let checker = (x / 4 + y / 4) % 2 == 0 ? Float(1.3) : Float(0.7)
                // One small specular source, well above diffuse white, so halation and the film
                // shoulder both have something to do.
                let specular = (x - 8) * (x - 8) + (y - 8) * (y - 8) < 4 ? Float(24) : Float(1)
                image.planes[0][index] = 0.02 + 0.9 * ramp * checker * specular
                image.planes[1][index] = 0.02 + 0.7 * (1 - ramp) * checker * specular
                image.planes[2][index] = 0.02 + 0.5 * ramp * ramp * checker * specular
            }
        }
        return image
    }

    private func options(stage: PipelineStage) -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.stage = stage
        options.format = .super35
        options.seed = 0x5EED
        return options
    }

    func testNegativeThenPrintReproducesFull() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        let image = scene()
        for stock in [TestStocks.negative, TestStocks.monochrome, TestStocks.reversal] {
            let full = FotufilmEngine(stock: stock, options: options(stage: .full))
                .process(linearRGB: image)
            let negative = FotufilmEngine(stock: stock, options: options(stage: .negative))
                .process(linearRGB: image)
            let split = FotufilmEngine(stock: stock, options: options(stage: .print))
                .process(linearRGB: negative)

            for channel in 0..<3 {
                for index in 0..<image.pixelCount {
                    let expected = full.planes[channel][index]
                    XCTAssertEqual(
                        split.planes[channel][index], expected,
                        // A delivered frame is written at sixteen bits; this is a hundredth of
                        // one of its steps, and the split writes float32 densities where the
                        // whole render kept them in a register.
                        accuracy: max(abs(expected), 1) * 1.5e-7,
                        "\(stock.name) channel \(channel) pixel \(index)")
                }
            }
        }
    }

    func testNegativeInterchangeStaysInsideItsStatedRange() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        // Push the exposure hard in both directions so the negative reaches its D-min at one end
        // and its shoulder at the other, well past anything a display would hold.
        for exposure in [Float(-6), -3, 0, 3, 6] {
            for stock in TestStocks.all {
                var settings = options(stage: .negative)
                settings.exposureEV = exposure
                let negative = FotufilmEngine(stock: stock, options: settings)
                    .process(linearRGB: scene())
                for channel in 0..<3 {
                    for value in negative.planes[channel] {
                        XCTAssertTrue(
                            NegativeInterchange.contains(value),
                            "\(stock.name) channel \(channel) left the interchange at \(value)")
                    }
                }
            }
        }
    }

    func testTheSplitCarriesDensitiesAboveDisplayWhite() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        var settings = options(stage: .negative)
        settings.exposureEV = 3
        let negative = FotufilmEngine(stock: TestStocks.negative, options: settings)
            .process(linearRGB: scene())
        let peak = negative.planes.flatMap { $0 }.max() ?? 0
        XCTAssertGreaterThan(peak, 1.5,
                             "a negative exposed three stops up should be denser than this")

        // And the print node reads them: a value clipped at display white on the way across would
        // flatten every highlight the negative was holding.
        let printed = FotufilmEngine(stock: TestStocks.negative, options: options(stage: .print))
            .process(linearRGB: negative)
        var clipped = negative
        for channel in 0..<3 {
            for index in 0..<clipped.pixelCount {
                clipped.planes[channel][index] = min(clipped.planes[channel][index], 1)
            }
        }
        let clippedPrint = FotufilmEngine(stock: TestStocks.negative,
                                         options: options(stage: .print))
            .process(linearRGB: clipped)
        let difference = (0..<printed.pixelCount).map {
            abs(printed.planes[0][$0] - clippedPrint.planes[0][$0])
        }.max() ?? 0
        XCTAssertGreaterThan(difference, 1e-3,
                             "clipping the interchange at 1.0 should change the print")
    }

    func testTextureWithNothingSelectedIsExactlyTheSource() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        let image = scene()
        for stock in TestStocks.all {
            var settings = options(stage: .texture)
            settings.textureStages = .none
            let result = FotufilmEngine(stock: stock, options: settings)
                .process(linearRGB: image)
            for channel in 0..<3 {
                for index in 0..<image.pixelCount {
                    XCTAssertEqual(result.planes[channel][index],
                                   image.planes[channel][index],
                                   accuracy: 0,
                                   "\(stock.name) channel \(channel) pixel \(index)")
                }
            }
        }
    }

    func testTextureIsANoOpOnAUniformField() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        for level in [Float(0.18), 0.02, 1.0, 8.0] {
            var image = ImageBuffer(width: 32, height: 32)
            for channel in 0..<3 {
                for index in 0..<image.pixelCount { image.planes[channel][index] = level }
            }
            var settings = options(stage: .texture)
            // Exclude grain because its random field is intentionally non-uniform.
            settings.textureStages = [.emulsionMTF, .halation, .adjacency, .enlarger]
            let result = FotufilmEngine(stock: TestStocks.negative, options: settings)
                .process(linearRGB: image)
            for channel in 0..<3 {
                for index in 0..<image.pixelCount {
                    XCTAssertEqual(result.planes[channel][index], level,
                                   accuracy: level * 2e-6,
                                   "channel \(channel) moved on a uniform field at \(level)")
                }
            }
        }
    }

    func testTextureGrainKeepsNeutralMidGrayAnchored() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        var image = ImageBuffer(width: 96, height: 96)
        for channel in 0..<3 {
            for index in 0..<image.pixelCount { image.planes[channel][index] = 0.18 }
        }
        var settings = options(stage: .texture)
        settings.textureStages = [.grain]
        let result = FotufilmEngine(stock: TestStocks.negative, options: settings)
            .process(linearRGB: image)
        for channel in 0..<3 {
            let mean = result.planes[channel].reduce(0, +) / Float(image.pixelCount)
            XCTAssertEqual(mean, 0.18, accuracy: 0.18 * 0.01,
                           "channel \(channel) mid-grey drifted to \(mean)")
            let moved = result.planes[channel].contains { abs($0 - 0.18) > 1e-5 }
            XCTAssertTrue(moved, "channel \(channel) shows no grain at all")
        }
    }

    func testATextureStageIsOfferedOnlyWhereTheStockHasOne() {
        var stock = TestStocks.negative
        XCTAssertEqual(TextureStages.offered(by: stock), .all,
                       "a colour negative should offer every spatial stage")

        stock.halationStrength = [0, 0, 0]
        XCTAssertFalse(TextureStages.offered(by: stock).contains(.halation),
                       "a base that returns no light has no halation to select")

        stock.adjacencyStrength = 0
        stock.couplerDiffusionMM = 0
        XCTAssertFalse(TextureStages.offered(by: stock).contains(.adjacency),
                       "couplers that do not diffuse leave no adjacency to select")
        XCTAssertTrue(TextureStages.offered(by: stock).contains(.grain),
                      "and the stages it still has stay offered")

        stock.grainStrength = 0
        XCTAssertFalse(TextureStages.offered(by: stock).contains(.grain))

        stock.emulsionDiffusionMM = [0, 0, 0]
        XCTAssertEqual(TextureStages.offered(by: stock), .enlarger,
                       "a stock with no spatial measurements at all still gets printed")

        stock.emulsionDiffusionSecondaryMM = [0.003, 0.0025, 0.002]
        stock.emulsionDiffusionPrimaryShare = [0, 0, 0]
        XCTAssertTrue(TextureStages.offered(by: stock).contains(.emulsionMTF),
                      "a secondary-only measured scale is still an emulsion MTF")

        var settings = options(stage: .texture)
        settings.textureStages = [.emulsionMTF]
        settings.format = FilmFormat(name: "test", frameHeightMM: 0.25)
        let invocation = FilmEngineInvocation(
            stock: stock, options: settings, width: 128, height: 128)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.mtf, 0)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.mtfLuma, 0,
                          "the extended MTF schedule must carry the second scale")
        let primaryShareRange = FilmEngineInvocation.mtfPrimaryShareOffset..<(FilmEngineInvocation.mtfPrimaryShareOffset + 3)
        XCTAssertEqual(
            Array(invocation.configuration[primaryShareRange]),
            [0, 0, 0])
        XCTAssertTrue(invocation.configuration[
            FilmEngineInvocation.mtfSecondaryRadiusOffset] > 0)
    }

    func testAReversalStockIsNotOfferedAnEnlarger() {
        XCTAssertFalse(TextureStages.offered(by: TestStocks.reversal).contains(.enlarger))
        XCTAssertTrue(TextureStages.offered(by: TestStocks.negative).contains(.enlarger))
    }

    func testWhatAFilmOffersIsWhatTheEngineRuns() {
        let bits: [(TextureStages, Int32)] = [
            (.emulsionMTF, FilmEngineFeature.mtf),
            (.halation, FilmEngineFeature.halation),
            (.grain, FilmEngineFeature.grain),
            (.enlarger, FilmEngineFeature.printMTF),
        ]
        for stock in TestStocks.all {
            let offered = TextureStages.offered(by: stock)
            for (spatial, bit) in bits {
                var settings = options(stage: .texture)
                settings.textureStages = spatial
                // A large frame, so a stage the stock does have is not withheld merely for
                // being narrower than a pixel at this size.
                let mask = FilmEngineInvocation(
                    stock: stock, options: settings, width: 3840, height: 2160).featureMask
                if !offered.contains(spatial) {
                    XCTAssertEqual(mask & bit, 0,
                                   "\(stock.name) does not offer \(spatial) but the engine "
                                   + "ran it anyway")
                }
            }
        }
    }

    func testNoSpanTurnsOnAStageTheFullRenderDidNotRun() {
        let image = ImageBuffer(width: 16, height: 16)
        for stock in TestStocks.all {
            let full = FilmEngineInvocation(
                stock: stock, options: options(stage: .full),
                width: image.width, height: image.height).featureMask
            for stage in PipelineStage.allCases {
                let mask = FilmEngineInvocation(
                    stock: stock, options: options(stage: stage),
                    width: image.width, height: image.height).featureMask
                let seams = FilmEngineFeature.densityIn | FilmEngineFeature.densityOut
                    | FilmEngineFeature.texture
                XCTAssertEqual(mask & ~seams & ~full, 0,
                               "\(stock.name) \(stage.name) added a stage")
            }
        }
    }
}
