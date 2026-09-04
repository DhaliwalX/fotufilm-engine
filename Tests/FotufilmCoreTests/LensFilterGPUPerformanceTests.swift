#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal

final class LensFilterGPUPerformanceTests: XCTestCase {
    private func frame(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let bright = (x % 211 < 4 && y % 197 < 4)
                pixels[i] = bright ? 255 : UInt8((x * 200) / max(width - 1, 1))
                pixels[i + 1] = bright ? 255 : UInt8((y * 210) / max(height - 1, 1))
                pixels[i + 2] = bright ? 255 : UInt8(200 - (x * 150) / max(width - 1, 1))
            }
        }
        return pixels
    }

    private func measure(_ options: FotufilmEngine.Options, width: Int, height: Int,
                         frames: Int = 8) throws -> Double {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let stock = FilmStock.presets["example-negative-400"]!
        let input = frame(width: width, height: height)
        var output = [UInt8](repeating: 0, count: width * height * 4)
        XCTAssertTrue(gpu.prepare(stock: stock, options: options,
                                  frameWidth: width, frameHeight: height))
        XCTAssertTrue(gpu.processSRGB8(input, into: &output, width: width, height: height,
                                       stock: stock, options: options, frameIndex: 0))
        var best = Double.infinity
        for index in 1...frames {
            let start = Date()
            XCTAssertTrue(gpu.processSRGB8(input, into: &output, width: width, height: height,
                                           stock: stock, options: options,
                                           frameIndex: UInt64(index)))
            best = min(best, Date().timeIntervalSince(start))
        }
        return best * 1000
    }

    func testGPUFrameCost() throws {
        var load: Double = 0
        getloadavg(&load, 1)
        print(String(format: "\nload average at start: %.2f", load))
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            print("--- \(width)x\(height), Metal frame schedule ---")
            var bare = FotufilmEngine.Options()
            bare.grainScale = 0
            let baseline = try measure(bare, width: width, height: height)
            print(String(format: "  %-40@ %7.2f ms", "no filter" as NSString, baseline))

            var absorbing = bare
            absorbing.lensFilters = LensFilterStack(.wratten85B)
            let filtered = try measure(absorbing, width: width, height: height)
            print(String(format: "  %-40@ %7.2f ms  %+6.2f ms", "85B (absorbing)" as NSString,
                         filtered, filtered - baseline))

            for (label, family, grade, focal) in [
                ("Black Pro-Mist 1/4 @ 50mm", DiffusionFilter.Family.blackProMist,
                 DiffusionFilter.Grade.quarter, Float(50)),
                ("Black Pro-Mist 1 @ 50mm", .blackProMist, .one, 50),
                ("Black Pro-Mist 1 @ 200mm", .blackProMist, .one, 200),
                ("Fog 1/2 @ 50mm", .fog, .half, 50),
            ] {
                var misty = bare
                misty.diffusionFilter = DiffusionFilter.preset(family, grade: grade)
                misty.focalLengthMM = focal
                let cost = try measure(misty, width: width, height: height)
                print(String(format: "  %-40@ %7.2f ms  %+6.2f ms  (%+.0f%%)",
                             label as NSString, cost, cost - baseline,
                             (cost / baseline - 1) * 100))
            }
        }
    }
}
#endif
