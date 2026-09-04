#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal

final class FramePerformanceTests: XCTestCase {
    func measureFrames(width: Int, height: Int, stock: FilmStock,
                       options: FotufilmEngine.Options, frames: Int) throws -> Double {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        var input = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                input[i] = UInt8((x * 255) / max(width - 1, 1))
                input[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                input[i + 2] = UInt8(((x + y) * 255) / max(width + height - 2, 1))
                input[i + 3] = 255
            }
        }
        var output = [UInt8](repeating: 0, count: width * height * 4)
        XCTAssertTrue(gpu.prepare(stock: stock, options: options,
                                  frameWidth: width, frameHeight: height))
        XCTAssertTrue(gpu.processSRGB8(input, into: &output, width: width,
                                       height: height, stock: stock,
                                       options: options, frameIndex: 0))
        var best = Double.infinity
        for frame in 1...frames {
            let start = Date()
            XCTAssertTrue(gpu.processSRGB8(
                input, into: &output, width: width, height: height,
                stock: stock, options: options, frameIndex: UInt64(frame)))
            best = min(best, Date().timeIntervalSince(start))
        }
        return best * 1000
    }

    func testFrameCost1080p() throws {
        let options = FotufilmEngine.Options()
        for stock in TestStocks.all {
            let ms = try measureFrames(width: 1920, height: 1080, stock: stock,
                                       options: options, frames: 20)
            print(String(format: "1080p %@: %.2f ms/frame (%.1f fps)",
                         stock.name, ms, 1000 / ms))
        }
    }

    func testFrameCostNegativeOnly() throws {
        let options = FotufilmEngine.Options()
        for (width, height, label) in [(1920, 1080, "1080p"), (3840, 2160, "4K")] {
            let ms = try measureFrames(width: width, height: height,
                                       stock: TestStocks.negative,
                                       options: options, frames: 60)
            print(String(format: "%@ negative: %.2f ms/frame (%.1f fps)",
                         label, ms, 1000 / ms))
        }
    }

    func testFrameCostBreakdown4K() throws {
        var options = FotufilmEngine.Options()
        let cases: [(String, (inout FotufilmEngine.Options) -> Void)] = [
            ("all stages", { _ in }),
            ("no grain", { $0.grainScale = 0 }),
            ("no halation", { $0.halationScale = 0 }),
            ("no couplers", { $0.couplerScale = 0 }),
            ("bare (none of the above)", {
                $0.grainScale = 0; $0.halationScale = 0; $0.couplerScale = 0
            }),
        ]
        for (label, apply) in cases {
            options = FotufilmEngine.Options()
            apply(&options)
            let ms = try measureFrames(width: 3840, height: 2160,
                                       stock: TestStocks.negative, options: options,
                                       frames: 40)
            print(String(format: "4K negative %@: %.2f ms/frame", label, ms))
        }
        var flat = TestStocks.negative
        flat.adjacencyStrength = 0
        let flatMs = try measureFrames(width: 3840, height: 2160, stock: flat,
                                       options: FotufilmEngine.Options(), frames: 40)
        print(String(format: "4K negative no adjacency: %.2f ms/frame", flatMs))
        var still = TestStocks.negative
        still.emulsionDiffusionMM = [0, 0, 0]
        still.emulsionDiffusionSecondaryMM = [0, 0, 0]
        still.emulsionDiffusionPrimaryShare = [1, 1, 1]
        let noMtf = try measureFrames(width: 3840, height: 2160, stock: still,
                                      options: FotufilmEngine.Options(), frames: 40)
        print(String(format: "4K negative no MTF: %.2f ms/frame", noMtf))
    }

    func testFrameCost4K() throws {
        let options = FotufilmEngine.Options()
        for stock in TestStocks.all {
            let ms = try measureFrames(width: 3840, height: 2160, stock: stock,
                                       options: options, frames: 20)
            print(String(format: "4K %@: %.2f ms/frame (%.1f fps)",
                         stock.name, ms, 1000 / ms))
        }
    }

    func testFrameCostBreakdown() throws {
        var options = FotufilmEngine.Options()
        let cases: [(String, (inout FotufilmEngine.Options) -> Void)] = [
            ("all stages", { _ in }),
            ("no grain", { $0.grainScale = 0 }),
            ("no halation", { $0.halationScale = 0 }),
            ("no couplers", { $0.couplerScale = 0 }),
            ("bare (none of the above)", {
                $0.grainScale = 0; $0.halationScale = 0; $0.couplerScale = 0
            }),
        ]
        for (label, apply) in cases {
            options = FotufilmEngine.Options()
            apply(&options)
            let ms = try measureFrames(width: 1920, height: 1080,
                                       stock: TestStocks.negative, options: options,
                                       frames: 20)
            print(String(format: "1080p negative %@: %.2f ms/frame", label, ms))
        }
        var narrow = TestStocks.negative
        narrow.couplerDiffusionMM = 0.005
        let narrowMs = try measureFrames(width: 1920, height: 1080, stock: narrow,
                                         options: FotufilmEngine.Options(), frames: 20)
        print(String(format: "1080p negative tiny coupler radius: %.2f ms/frame", narrowMs))
        var flat = TestStocks.negative
        flat.adjacencyStrength = 0
        let flatMs = try measureFrames(width: 1920, height: 1080, stock: flat,
                                       options: FotufilmEngine.Options(), frames: 20)
        print(String(format: "1080p negative no adjacency: %.2f ms/frame", flatMs))
        for size in [(960, 540), (480, 270)] {
            let ms = try measureFrames(width: size.0, height: size.1,
                                       stock: TestStocks.negative,
                                       options: FotufilmEngine.Options(), frames: 20)
            print(String(format: "%dx%d negative all stages: %.2f ms/frame",
                         size.0, size.1, ms))
        }
    }
}
#endif
