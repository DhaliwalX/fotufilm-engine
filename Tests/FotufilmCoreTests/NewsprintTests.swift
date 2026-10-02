import XCTest
import FotufilmHalide
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class NewsprintTests: XCTestCase {
    private let papers: [PrintPaper] = [.newsprintColor, .newsprintBW]

    private func options(_ paper: PrintPaper) -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.paper = paper
        options.grainScale = 0; options.halationScale = 0; options.couplerScale = 0
        options.localTone = false
        return options
    }

    func testSelectionPersistenceAndMatteBorder() throws {
        XCTAssertEqual(Array(PrintPaper.allCases.prefix(12)), [
            .ektacolorEdge, .enduraPremier, .crystalArchive, .vision2383, .vision2393,
            .eternaCP, .labScan, .telecine, .screen, .negative, .ilfochromeCPS1K, .ilfochromeCLM1K])
        for paper in papers {
            XCTAssertEqual(PrintPaper.preset(id: paper.id), paper)
            for stock in [TestStocks.negative, TestStocks.monochrome, TestStocks.reversal] {
                XCTAssertEqual(paper.resolved(for: stock), paper)
                XCTAssertFalse(paper.supportsHDRDelivery(for: stock))
            }
            let frame = PrintFrameConfiguration(frame: .paper, formatID: "35mm",
                stockID: "portra400", paper: paper)
            XCTAssertEqual(frame.frame, .paper)
            XCTAssertFalse(frame.hasLustre)
            XCTAssertEqual(frame.baseRGB, SIMD3<Float>(0.88, 0.84, 0.73))
            XCTAssertTrue(frame.detail.contains("matte"))
            let invocation = try FilmEngineInvocation(validating: TestStocks.negative,
                options: options(paper), width: 1200, height: 800)
            XCTAssertEqual(invocation.configuration[Int(FOTUFILM_CONFIG_NEWSPRINT + 1)], 8)
        }
    }

    func testTintIsScreenedAndBWUsesOneInk() throws {
        try XCTSkipUnless(HalideBackend.isAvailable)
        let stock = TestStocks.negative
        let width = 480, height = 400
        var input = ImageBuffer(width: width, height: height)
        for c in 0..<3 { input.planes[c] = Array(repeating: [Float(0.6), 0.16, 0.04][c], count: input.pixelCount) }
        for paper in papers {
            let result = try XCTUnwrap(HalideBackend.process(image: input, stock: stock, options: options(paper)))
            let red = result.planes[0]
            XCTAssertGreaterThan((red.max() ?? 0) - (red.min() ?? 0), 0.15, "A flat tint must contain visible dots")
            var chroma: Float = 0
            for i in 0..<input.pixelCount {
                let difference = abs(result.planes[0][i] / 0.88 - result.planes[2][i] / 0.73)
                chroma = max(chroma, difference)
                for c in 0..<3 {
                    XCTAssertTrue(result.planes[c][i].isFinite)
                    XCTAssertGreaterThanOrEqual(result.planes[c][i], 0)
                    XCTAssertLessThanOrEqual(result.planes[c][i], 0.88)
                }
            }
            if paper == .newsprintBW { XCTAssertLessThan(chroma, 1e-5) }
            else { XCTAssertGreaterThan(chroma, 0.1) }
        }
    }

    func testCompactTileKeepsFullFrameScreenPhase() throws {
        try XCTSkipUnless(HalideBackend.isAvailable)
        // A constant patch isolates screen phase from metering and optical aprons.
        let width = 613, height = 407, tw = 71, th = 53, x = 137, y = 89
        var image = ImageBuffer(width: width, height: height)
        for c in 0..<3 { image.planes[c] = Array(repeating: [Float(0.5), 0.18, 0.07][c], count: image.pixelCount) }
        for paper in papers {
            let o = options(paper)
            let whole = try XCTUnwrap(HalideBackend.process(image: image, stock: TestStocks.negative, options: o))
            let invocation = try FilmEngineInvocation(validating: TestStocks.negative, options: o, width: width, height: height)
            let count = tw * th
            let input = (0..<3).flatMap { c in Array(repeating: image.planes[c][0], count: count) }
            var output = [Float](repeating: -1, count: count * 3)
            let status = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { target in
                    invocation.configuration.withUnsafeBufferPointer { config in
                        invocation.withSpectralPointers { exposure, film, paper in
                            fotufilm_halide_process_region(source.baseAddress!, source.baseAddress! + count,
                                source.baseAddress! + 2 * count, target.baseAddress!, target.baseAddress! + count,
                                target.baseAddress! + 2 * count, Int32(tw), Int32(th), Int32(width), Int32(height),
                                Int32(x), Int32(y), 0, 0, Int32(tw), Int32(th), config.baseAddress!,
                                exposure, film, paper, Int32(invocation.spectral.exposure.dimension),
                                invocation.featureMask, invocation.seed, nil)
                        }
                    }
                }
            }
            XCTAssertEqual(status, 0)
            var worst: Float = 0
            for c in 0..<3 { for row in 0..<th { for column in 0..<tw {
                worst = max(worst, abs(output[c * count + row * tw + column]
                    - whole.planes[c][(y + row) * width + x + column]))
            } } }
            XCTAssertLessThan(worst, 1e-5)
        }
    }

#if canImport(Metal)
    func testCPUAndMetalAgreeForColorMonochromeAndSlide() throws {
        try XCTSkipUnless(HalideBackend.isAvailable)
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let width = 401, height = 307
        var input = ImageBuffer(width: width, height: height)
        var rgba = [Float](repeating: 1, count: input.pixelCount * 4)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            let value = 0.02 + Float((x + c * 101 + y / 3) % width) / Float(width)
            input.planes[c][y * width + x] = value
            rgba[(y * width + x) * 4 + c] = value
        } } }
        for stock in [TestStocks.negative, TestStocks.monochrome, TestStocks.reversal] {
            for paper in papers {
                let o = options(paper)
                let cpu = try XCTUnwrap(HalideBackend.process(image: input, stock: stock, options: o))
                let metal = try XCTUnwrap(gpu.processLinearFloat(rgba, width: width, height: height,
                    stock: stock, options: o, frameIndex: 0))
                var worst: Float = 0
                for c in 0..<3 { for i in 0..<input.pixelCount {
                    worst = max(worst, abs(cpu.planes[c][i] - metal[i * 4 + c]))
                } }
                XCTAssertLessThan(worst, 0.002, "\(paper.name) / \(stock.name)")
            }
        }
    }
#endif
}
