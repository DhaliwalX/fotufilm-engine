import XCTest
@testable import FotufilmCore

final class FilmFormatTests: XCTestCase {
    func uniform(_ v: Float, size: Int) -> ImageBuffer {
        var img = ImageBuffer(width: size, height: size)
        for c in 0..<3 {
            for i in 0..<img.pixelCount { img.planes[c][i] = v }
        }
        return img
    }

    func neighborCorrelation(_ plane: [Float], width: Int, height: Int) -> Float {
        var mean: Float = 0
        for v in plane { mean += v }
        mean /= Float(plane.count)
        var cov: Float = 0, variance: Float = 0
        var count = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let a = plane[y * width + x] - mean
                let b = plane[y * width + x + 1] - mean
                cov += a * b
                variance += a * a
                count += 1
            }
        }
        return variance > 0 ? cov / variance : 0
    }

    func testSmallerGaugeShowsCoarserGrain() {
        let size = 768
        var options = FotufilmEngine.Options()
        options.halationScale = 0

        options.format = .super8
        let super8 = FotufilmEngine(stock: TestStocks.negative, options: options)
            .process(linearRGB: uniform(0.18, size: size))
        options.format = .still35
        let still35 = FotufilmEngine(stock: TestStocks.negative, options: options)
            .process(linearRGB: uniform(0.18, size: size))

        let corr8 = neighborCorrelation(super8.planes[1], width: size, height: size)
        let corr35 = neighborCorrelation(still35.planes[1], width: size, height: size)
        // A 5 µm clump is sub-pixel on every gauge but Super 8 at this size, so 35mm reads the
        // white noise its floored blur produces and the comparison is resolved clump against no
        // clump. Measured 0.198 against -0.0007; a gauge that did not reach the grain scale would
        // put the two within noise of each other.
        XCTAssertGreaterThan(corr8, corr35 + 0.15,
                             "super8 grain corr \(corr8) should be far above 35mm \(corr35)")
    }

    func testSmallerGaugeSpreadsHalationFurther() {
        let size = 256
        var img = ImageBuffer(width: size, height: size)
        for y in 112..<144 {
            for x in 112..<144 {
                let i = y * size + x
                img.planes[0][i] = 4; img.planes[1][i] = 4; img.planes[2][i] = 4
            }
        }
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        let probe = 152 * size + 128

        func redAt(_ format: FilmFormat) -> Float {
            options.format = format
            return FotufilmEngine(stock: TestStocks.negative, options: options)
                .process(linearRGB: img).planes[0][probe]
        }
        options.halationScale = 0
        options.format = .still35
        let noHalation = FotufilmEngine(stock: TestStocks.negative, options: options)
            .process(linearRGB: img).planes[0][probe]
        options.halationScale = 1
        let glow16 = redAt(.sixteenMM) - noHalation
        let glow35 = redAt(.still35) - noHalation
        XCTAssertGreaterThan(glow16, glow35 + 1e-4,
                             "16mm glow \(glow16) should exceed 35mm glow \(glow35)")
    }

    func testCropCoverageConfiguresLikeTheSmallerGaugeItIs() {
        // A 50% crop of the 135 frame shown at the same size is an enlargement of a
        // 12 mm-tall piece of the same film on the same base, so the engine must
        // configure exactly as it would for a gauge of that height — every
        // millimetre-sized structure (grain, MTF, halation, adjacency, coupler
        // diffusion) doubled in pixels.
        var cropped = FotufilmEngine.Options()
        cropped.format = .still35
        cropped.frameCoverage = 0.5
        var halfGauge = cropped
        halfGauge.format = FilmFormat(
            name: "half of 135", frameHeightMM: 12,
            frameAspectRatio: FilmFormat.still35.frameAspectRatio,
            base: FilmFormat.still35.base)
        halfGauge.frameCoverage = 1
        let stock = TestStocks.negative
        let croppedInvocation = FilmEngineInvocation(
            stock: stock, options: cropped, width: 512, height: 384)
        let gaugeInvocation = FilmEngineInvocation(
            stock: stock, options: halfGauge, width: 512, height: 384)
        XCTAssertEqual(croppedInvocation.configuration,
                       gaugeInvocation.configuration)
        XCTAssertEqual(croppedInvocation.featureMask, gaugeInvocation.featureMask)
        XCTAssertEqual(croppedInvocation.spatialSupport,
                       gaugeInvocation.spatialSupport)

        // The coverage has to change the configuration at all, or the two
        // assertions above would pass vacuously on a scale the engine ignores.
        var full = cropped
        full.frameCoverage = 1
        let fullInvocation = FilmEngineInvocation(
            stock: stock, options: full, width: 512, height: 384)
        XCTAssertNotEqual(croppedInvocation.configuration,
                          fullInvocation.configuration)

        // A degenerate sliver clamps rather than asking for unbounded radii.
        var sliver = cropped
        sliver.frameCoverage = 0.001
        var floor = cropped
        floor.frameCoverage = 0.05
        XCTAssertEqual(
            FilmEngineInvocation(stock: stock, options: sliver,
                                 width: 512, height: 384).configuration,
            FilmEngineInvocation(stock: stock, options: floor,
                                 width: 512, height: 384).configuration)
    }

    func testFormatPresetsResolve() {
        XCTAssertEqual(FilmFormat.preset(id: "16mm"), .sixteenMM)
        XCTAssertNil(FilmFormat.preset(id: "70mm"))
        let heights = FilmFormat.presets.map { $0.format.frameHeightMM }
        XCTAssertEqual(heights, heights.sorted())
    }

    func testNativeGaugeFallsBackTo35mm() {
        XCTAssertEqual(FilmFormat.nativeID(forStockID: "no-such-stock"), "35mm")
        XCTAssertEqual(FilmFormat.native(forStockID: "no-such-stock"), .still35)
    }

    func testNativeGaugeReadsThePack() throws {
        for (id, definition) in FilmStock.presetDefinitions {
            guard let named = definition.nativeFormatID else { continue }
            XCTAssertNotNil(FilmFormat.preset(id: named),
                            "\(id) names gauge '\(named)', which is not a preset")
            XCTAssertEqual(FilmFormat.nativeID(forStockID: id), named)
        }

        for id in ["vision250d", "vision500t", "doublex5222"]
        where FilmStock.presetDefinitions[id] != nil {
            XCTAssertEqual(FilmFormat.nativeID(forStockID: id), "super35")
        }
    }

    func testUnknownGaugeNameFallsBackRatherThanFailing() throws {
        guard var definition = FilmStock.presetDefinitions.values.first else {
            throw XCTSkip("no stock pack installed")
        }
        definition.nativeFormatID = "70mm"
        let data = try JSONEncoder().encode(definition)
        let round = try JSONDecoder().decode(FilmStockDefinition.self, from: data)
        XCTAssertEqual(round.nativeFormatID, "70mm")
        XCTAssertNil(FilmFormat.preset(id: "70mm"))
    }
}
