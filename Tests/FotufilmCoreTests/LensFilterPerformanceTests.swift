import XCTest
@testable import FotufilmCore

final class LensFilterPerformanceTests: XCTestCase {

    private static var stock: FilmStock {
        FilmStock.presets["example-negative-400"]!
    }

    private func scene(width: Int, height: Int) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                // Gradients plus a bright edge, so the spatial stages have structure to work on.
                let u = Float(x) / Float(width - 1), v = Float(y) / Float(height - 1)
                let spike: Float = (x % 97 < 3 && y % 89 < 3) ? 40 : 0
                image.planes[0][i] = 0.02 + u * 0.8 + spike
                image.planes[1][i] = 0.02 + v * 0.7 + spike
                image.planes[2][i] = 0.02 + (1 - u) * 0.6 + spike
            }
        }
        return image
    }

    private func milliseconds(_ options: FotufilmEngine.Options,
                              width: Int, height: Int, runs: Int = 5) -> Double {
        let image = scene(width: width, height: height)
        let simulator = FotufilmEngine(stock: Self.stock, options: options)
        _ = simulator.process(linearRGB: image)      // warm the pipeline and the tables
        var best = Double.infinity
        for _ in 0..<runs {
            let start = Date()
            _ = simulator.process(linearRGB: image)
            best = min(best, Date().timeIntervalSince(start))
        }
        return best * 1000
    }

    func testWhatTheFiltersCost() {
        var load: Double = 0
        getloadavg(&load, 1)
        print(String(format: "load average at start: %.2f", load))

        for (width, height) in [(1920, 1080), (3840, 2160)] {
            print("\n--- \(width)x\(height), CPU Halide, grain off ---")
            var bare = FotufilmEngine.Options()
            bare.grainScale = 0
            let baseline = milliseconds(bare, width: width, height: height)
            print(String(format: "  %-42@ %7.1f ms", "no filter" as NSString, baseline))

            var absorbing = bare
            absorbing.lensFilters = LensFilterStack(.wratten85B)
            let withFilter = milliseconds(absorbing, width: width, height: height)
            print(String(format: "  %-42@ %7.1f ms  %+6.1f ms", "85B (absorbing)" as NSString,
                         withFilter, withFilter - baseline))

            var stacked = bare
            stacked.lensFilters = LensFilterStack([.wratten85B, .nd09, .cc(.magenta, density: 0.20)])
            let withStack = milliseconds(stacked, width: width, height: height)
            print(String(format: "  %-42@ %7.1f ms  %+6.1f ms", "85B + ND0.9 + CC20M" as NSString,
                         withStack, withStack - baseline))

            for (label, family, grade, focal) in [
                ("diffusion, Black Pro-Mist 1/4 @ 50mm", DiffusionFilter.Family.blackProMist,
                 DiffusionFilter.Grade.quarter, Float(50)),
                ("diffusion, Black Pro-Mist 1 @ 50mm", .blackProMist, .one, 50),
                ("diffusion, Black Pro-Mist 1 @ 200mm", .blackProMist, .one, 200),
                ("diffusion, Fog 1/2 @ 50mm", .fog, .half, 50),
            ] {
                var misty = bare
                misty.diffusionFilter = DiffusionFilter.preset(family, grade: grade)
                misty.focalLengthMM = focal
                let cost = milliseconds(misty, width: width, height: height)
                print(String(format: "  %-42@ %7.1f ms  %+6.1f ms  (%+.0f%%)",
                             label as NSString, cost, cost - baseline,
                             (cost / baseline - 1) * 100))
            }
        }
    }

    func testHostSideInvocationCost() {
        let stack = LensFilterStack([.wratten85B, .nd09])
        var options = FotufilmEngine.Options()
        options.lensFilters = stack
        options.diffusionFilter = DiffusionFilter.preset(.blackProMist, grade: .quarter)
        var bare = FotufilmEngine.Options()
        bare.grainScale = 0
        options.grainScale = 0

        func invocations(_ o: FotufilmEngine.Options, _ n: Int) -> Double {
            _ = FilmEngineInvocation(stock: Self.stock, options: o, width: 1920, height: 1080)
            let start = Date()
            for _ in 0..<n {
                _ = FilmEngineInvocation(stock: Self.stock, options: o,
                                         width: 1920, height: 1080)
            }
            return Date().timeIntervalSince(start) / Double(n) * 1000
        }
        let plain = invocations(bare, 200)
        let fitted = invocations(options, 200)
        print(String(format: "\n--- per-frame host setup (FilmEngineInvocation) ---"))
        print(String(format: "  no filters      %6.3f ms", plain))
        print(String(format: "  filters fitted  %6.3f ms  %+.3f ms", fitted, fitted - plain))
    }

    func testExposureTableBuildCost() {
        let stock = Self.stock
        var built: [Double] = []
        for density in [Float(0.11), 0.12, 0.13, 0.14] {
            let stack = LensFilterStack(.neutralDensity(density))
            let start = Date()
            _ = SpectralRuntime.filteredExposure(for: stock, cct: nil, stack: stack)
            built.append(Date().timeIntervalSince(start) * 1000)
        }
        let stack = LensFilterStack(.neutralDensity(0.11))
        let start = Date()
        _ = SpectralRuntime.filteredExposure(for: stock, cct: nil, stack: stack)
        let cached = Date().timeIntervalSince(start) * 1000
        print(String(format: "\n--- filtered exposure table (33^3) ---"))
        print(String(format: "  first build   %7.1f ms (min of %d: %.1f)",
                     built.max() ?? 0, built.count, built.min() ?? 0))
        print(String(format: "  cache hit     %7.4f ms", cached))
    }
}
