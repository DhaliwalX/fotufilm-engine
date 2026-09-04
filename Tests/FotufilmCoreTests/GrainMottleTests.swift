import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import Metal
import FotufilmMetal
#endif

final class GrainMottleTests: XCTestCase {

    private static var stock: FilmStock {
        FilmStock.presets["example-negative-400"]!
    }

    private func invocation(share: Float?) -> FilmEngineInvocation {
        var options = FotufilmEngine.Options()
        options.grainMottleShare = share
        return FilmEngineInvocation(stock: Self.stock, options: options,
                                    width: 4000, height: 2667)
    }

    func testOffIsBitIdentical() {
        let plain = invocation(share: nil)
        let explicit = invocation(share: 0)
        XCTAssertEqual(plain.featureMask, explicit.featureMask)
        XCTAssertEqual(plain.configuration, explicit.configuration)
        XCTAssertEqual(plain.featureMask & FilmEngineFeature.grainMottle, 0)
        let offset = FilmEngineInvocation.mottleOffset
        for slot in offset..<(offset + 3) {
            XCTAssertEqual(plain.configuration[slot], 0)
        }
        XCTAssertEqual(Self.stock.grainMottleShare, 0)
    }

    func testMixtureLaysTheCoarseFieldAtItsOwnSize() {
        let mixed = invocation(share: 0.4)
        XCTAssertNotEqual(mixed.featureMask & FilmEngineFeature.grainMottle, 0)
        let fineSigma = mixed.configuration[FilmEngineInvocation.grainSigmaOffset]
        let mottleSigma = mixed.configuration[FilmEngineInvocation.mottleSigmaOffset]
        // 2667 px over the 24 mm frame. Both populations also carry the enlarger's shortfall:
        // Ektacolor's 4 µm spread is 0.44 px here, and the sampled kernel that stands for it on
        // this lattice delivers barely half of that, so what it fails to perform rides on the
        // clumps instead. Written out from the paper's own figure rather than read off the
        // engine, so a hand-over that fell back to the old all-or-nothing threshold — which
        // handed the grain nothing at all at this size — still fails here.
        let paper = PrintPaper.default(for: Self.stock)
        let pxPerMM = Float(2667) / FotufilmEngine.Options().format.frameHeightMM
        let clumpPixels = Self.stock.grainClumpSigmaMM * pxPerMM
        let enlargerPixels = paper.enlargerBlurMM * pxPerMM
        let foldPixels = (enlargerPixels * enlargerPixels
            - FilmEngineInvocation.sampledGaussianVariance(enlargerPixels)).squareRoot()
        XCTAssertGreaterThan(foldPixels, 0.1,
                             "this lattice is meant to leave the grain a real shortfall")
        XCTAssertEqual(fineSigma,
                       FilmEngineInvocation.discreteGrainSigma(
                           clumpSigmaPixels: clumpPixels,
                           foldSigmaPixels: foldPixels,
                           foldKeep: paper.scanSharpening),
                       accuracy: 1e-4)
        XCTAssertEqual(mottleSigma,
                       FilmEngineInvocation.discreteGrainSigma(
                           clumpSigmaPixels: clumpPixels * Self.stock.grainMottleSizeRatio,
                           foldSigmaPixels: foldPixels,
                           foldKeep: paper.scanSharpening),
                       accuracy: 1e-4)
        XCTAssertGreaterThan(mottleSigma, fineSigma)
        // Four times the sampling density resolves both populations further, and the rendered
        // ratio climbs back toward the physical one it can never exceed.
        let resolved = FilmEngineInvocation(
            stock: Self.stock, options: FotufilmEngine.Options(),
            width: 16000, height: 10668)
        let resolvedRatio = resolved.configuration[FilmEngineInvocation.mottleSigmaOffset]
            / resolved.configuration[FilmEngineInvocation.grainSigmaOffset]
        XCTAssertGreaterThan(resolvedRatio, mottleSigma / fineSigma)
        XCTAssertLessThanOrEqual(resolvedRatio, Self.stock.grainMottleSizeRatio + 0.01)
        let offset = FilmEngineInvocation.mottleOffset
        for slot in offset..<(offset + 3) {
            XCTAssertNotEqual(mixed.configuration[slot], 0)
        }
    }

    func testPublishedGranularityIsConservedAcrossTheSplit() {
        let stock = Self.stock
        let pxPerMM = Float(2667) / FotufilmEngine.Options().format.frameHeightMM
        let aperture = sqrt(Float.pi) * FilmStock.granularityApertureRadiusMM * pxPerMM
        for share: Float in [0, 0.25, 0.4, 0.9] {
            let inv = invocation(share: share)
            for layer in 0..<3 {
                // Each component's aperture correction is taken against the clump size on
                // the film, which is where the correction lives: the same physical clump
                // reads the same through a 48 µm aperture whatever the export resolution.
                // Reading it off the rendered sigma instead would make this test agree with
                // an engine that let granularity drift with pixel count.
                let fineMM = stock.grainClumpSigmaMM * stock.grainLayerSizeRatio[layer]
                let mottleMM = fineMM * stock.grainMottleSizeRatio
                let fineScale = aperture / FilmStock.granularityApertureResponse(
                    clumpSigmaMM: fineMM)
                let mottleScale = aperture / FilmStock.granularityApertureResponse(
                    clumpSigmaMM: mottleMM)
                // The density law is normalised at the sheet's own read density, so the
                // amplitude the engine carries is the published figure itself — no anchor
                // modulation to divide back out.
                let fine = inv.configuration[FilmEngineInvocation.grainOffset + layer]
                    / fineScale
                let mottle = inv.configuration[FilmEngineInvocation.mottleOffset + layer]
                    / mottleScale
                let anchored = (fine * fine + mottle * mottle).squareRoot()
                XCTAssertEqual(anchored,
                               stock.grainStrength * stock.grainLayerWeights[layer],
                               accuracy: 1e-5,
                               "share \(share) layer \(layer)")
            }
        }
    }

    func testSizeRatioOverrideMatchesAStockCarryingIt() {
        var options = FotufilmEngine.Options()
        options.grainMottleShare = 0.35
        options.grainMottleSizeRatio = 8
        let overridden = FilmEngineInvocation(stock: Self.stock, options: options,
                                              width: 4000, height: 2667)

        var carried = Self.stock
        carried.grainMottleShare = 0.35
        carried.grainMottleSizeRatio = 8
        let native = FilmEngineInvocation(stock: carried,
                                          options: FotufilmEngine.Options(),
                                          width: 4000, height: 2667)
        XCTAssertEqual(overridden.featureMask, native.featureMask)
        XCTAssertEqual(overridden.configuration, native.configuration)

        // The clamp: an option past the pack's validated ceiling renders the ceiling.
        var wild = options
        wild.grainMottleSizeRatio = 40
        let clamped = FilmEngineInvocation(stock: Self.stock, options: wild,
                                           width: 4000, height: 2667)
        XCTAssertEqual(clamped.configuration, overridden.configuration)
    }

    func testDeliveryCompletionFillsOnlyTheRatioOfAnExplicitShare() {
        var asked = FotufilmEngine.Options()
        asked.grainMottleShare = 0.35
        asked.completeDeliveryMottle()
        XCTAssertEqual(asked.grainMottleSizeRatio,
                       FotufilmEngine.Options.deliveryMottleSizeRatio)

        var chosen = FotufilmEngine.Options()
        chosen.grainMottleShare = 0.35
        chosen.grainMottleSizeRatio = 4
        chosen.completeDeliveryMottle()
        XCTAssertEqual(chosen.grainMottleSizeRatio, 4)

        var silent = FotufilmEngine.Options()
        silent.completeDeliveryMottle()
        XCTAssertNil(silent.grainMottleShare)
        XCTAssertNil(silent.grainMottleSizeRatio)
    }

#if canImport(Metal)
    private static var resolvedGrain: FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.format = FilmFormat(name: "resolved grain", frameHeightMM: 1.2)
        return options
    }

    private static func flatGrey(side: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for index in 0..<(side * side) {
            pixels[index * 4] = 128
            pixels[index * 4 + 1] = 128
            pixels[index * 4 + 2] = 128
        }
        return pixels
    }

    private static func correlation(_ image: [UInt8], side: Int,
                                    lag: Int) -> Double {
        var values = [Double]()
        values.reserveCapacity(side * side)
        for index in 0..<(side * side) {
            values.append(Double(image[index * 4 + 1]))
        }
        let mean = values.reduce(0, +) / Double(values.count)
        var variance = 0.0, covariance = 0.0, pairs = 0
        for y in 0..<side {
            for x in 0..<side {
                let centred = values[y * side + x] - mean
                variance += centred * centred
                if x + lag < side {
                    covariance += centred * (values[y * side + x + lag] - mean)
                    pairs += 1
                }
            }
        }
        guard variance > 0, pairs > 0 else { return 0 }
        return covariance / Double(pairs) / (variance / Double(side * side))
    }

    func testMetalLaysTheCoarseFieldToo() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let side = 192
        let pixels = Self.flatGrey(side: side)
        func render(share: Float?) throws -> [UInt8] {
            var options = Self.resolvedGrain
            options.grainMottleShare = share
            return try XCTUnwrap(
                gpu.processSRGB8(pixels, width: side, height: side,
                                 stock: Self.stock, options: options))
        }
        let plain = try render(share: nil)
        let mixed = try render(share: 0.6)

        var differing = 0
        for index in 0..<(side * side) where plain[index * 4 + 1] != mixed[index * 4 + 1] {
            differing += 1
        }
        XCTAssertGreaterThan(
            differing, side * side / 10,
            "the GPU rendered the same field with and without the mixture")

        let plainCorrelation = Self.correlation(plain, side: side, lag: 2)
        let mixedCorrelation = Self.correlation(mixed, side: side, lag: 2)
        XCTAssertGreaterThan(
            mixedCorrelation, plainCorrelation + 0.02,
            "the mixture's coarse population should widen the field: "
            + "plain \(plainCorrelation), mixed \(mixedCorrelation)")
    }

    func testMetalGivesEachLayerItsOwnClumpSize() throws {
        guard let gpu = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Halide Metal unavailable")
        }
        // No installed sheet carries per-layer geometry yet, so the ratios are set here rather
        // than read: on the [1, 1, 1] default every layer is the same size and there is nothing
        // for this to measure.
        var stock = Self.stock
        stock.grainLayerSizeRatio = [1, 1, 4]
        let side = 192
        let bytes = side * side * 16
        guard let input = device.makeBuffer(length: bytes,
                                            options: .storageModeShared),
              let output = device.makeBuffer(length: bytes,
                                             options: .storageModeShared) else {
            throw XCTSkip("no shared Metal buffers")
        }
        let source = input.contents().assumingMemoryBound(to: Float.self)
        for index in 0..<(side * side) {
            source[index * 4] = 0.18
            source[index * 4 + 1] = 0.18
            source[index * 4 + 2] = 0.18
            source[index * 4 + 3] = 1
        }
        XCTAssertTrue(gpu.processLinearFloat(
            input: input, output: output, width: side, height: side,
            stock: stock, options: Self.resolvedGrain, realtime: true))

        let rendered = output.contents().assumingMemoryBound(to: Float.self)
        func correlation(channel: Int) -> Double {
            var values = [Double]()
            values.reserveCapacity(side * side)
            for index in 0..<(side * side) {
                values.append(Double(rendered[index * 4 + channel]))
            }
            let mean = values.reduce(0, +) / Double(values.count)
            var variance = 0.0, covariance = 0.0
            for y in 0..<side {
                for x in 0..<side {
                    let centred = values[y * side + x] - mean
                    variance += centred * centred
                    if x + 2 < side {
                        covariance += centred * (values[y * side + x + 2] - mean)
                    }
                }
            }
            guard variance > 0 else { return 0 }
            return covariance / variance
        }
        let red = correlation(channel: 0)
        let blue = correlation(channel: 2)
        XCTAssertGreaterThan(
            blue, red + 0.02,
            "the blue layer's clumps are four times the red layer's and should "
            + "stay correlated further: red \(red), blue \(blue)")
    }
#endif

    func testPackRoundTripAndSilentDefault() throws {
        var stock = Self.stock
        stock.grainMottleShare = 0.35
        stock.grainMottleSizeRatio = 4
        let definition = FilmStockDefinition(id: "mottle-test", stock: stock)
        XCTAssertEqual(definition.grainMottleShare, 0.35)
        XCTAssertEqual(definition.grainMottleSizeRatio, 4)
        let revived = definition.stock
        XCTAssertEqual(revived.grainMottleShare, 0.35)
        XCTAssertEqual(revived.grainMottleSizeRatio, 4)

        let silent = try JSONDecoder().decode(
            FilmStockDefinition.self,
            from: try JSONEncoder().encode(
                FilmStockDefinition(id: "silent-test", stock: Self.stock)))
        XCTAssertEqual(silent.stock.grainMottleShare, 0)
        XCTAssertEqual(silent.stock.grainMottleSizeRatio, 3)
    }
}
