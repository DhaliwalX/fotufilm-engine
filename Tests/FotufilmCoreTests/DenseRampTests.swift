#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class DenseRampTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide engine required")
    }

    private static let grid = 16
    private static let patch = 16
    private static var side: Int { grid * patch }
    private static var levels: Int { grid * grid }

    private static let lowStop: Float = -7
    private static let highStop: Float = 5

    private static func sceneLight(level: Int) -> Float {
        let t = Float(level) / Float(levels - 1)
        return 0.18 * pow(2, lowStop + (highStop - lowStop) * t)
    }

    private static func centre(of level: Int) -> (x: Int, y: Int) {
        let column = level % grid, row = level / grid
        return (column * patch + patch / 2, row * patch + patch / 2)
    }

    private static func code(_ linear: Float) -> Double {
        Double(ColorScience.linearToSrgb(ColorScience.displayShoulder(linear)))
            * 255
    }

    private static func wedge() -> [Float] {
        var pixels = [Float](repeating: 1, count: side * side * 4)
        for level in 0..<levels {
            let light = sceneLight(level: level)
            let origin = centre(of: level)
            for dy in 0..<patch {
                for dx in 0..<patch {
                    let x = origin.x - patch / 2 + dx
                    let y = origin.y - patch / 2 + dy
                    let i = (y * side + x) * 4
                    pixels[i] = light
                    pixels[i + 1] = light
                    pixels[i + 2] = light
                    pixels[i + 3] = 1
                }
            }
        }
        return pixels
    }

    private static func wedgeBuffer() -> ImageBuffer {
        var image = ImageBuffer(width: side, height: side)
        let interleaved = wedge()
        for i in 0..<(side * side) {
            for c in 0..<3 { image.planes[c][i] = interleaved[i * 4 + c] }
        }
        return image
    }

    private static func options() -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.halationScale = 0
        options.couplerScale = 0
        return options
    }

    private static func withoutFlare(_ stock: FilmStock) -> FilmStock {
        var flat = stock
        flat.flare = 0
        return flat
    }

    private struct Ripple {
        var worst = 0.0
        var atCode = 0.0
        var atLevel = 0
        var mean = 0.0
        var darkest = 255.0
        var brightest = 0.0

        mutating func add(_ level: Int, reference: Double, other: Double) {
            let d = abs(reference - other)
            mean += d
            darkest = min(darkest, reference)
            brightest = max(brightest, reference)
            if d > worst {
                worst = d
                atCode = reference
                atLevel = level
            }
        }
    }

    func testMetalMatchesCPUOnADenseNeutralRamp() throws {
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared,
                                "Halide Metal unavailable")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let side = Self.side
        let bytes = side * side * 16
        let input = try XCTUnwrap(
            device.makeBuffer(length: bytes, options: .storageModeShared))
        let output = try XCTUnwrap(
            device.makeBuffer(length: bytes, options: .storageModeShared))
        let options = Self.options()
        let interleaved = Self.wedge()
        interleaved.withUnsafeBufferPointer {
            input.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes)
        }

        for stock in TestStocks.all.map(Self.withoutFlare) {
            let cpu = FotufilmEngine(stock: stock, options: options)
                .process(linearRGB: Self.wedgeBuffer())

            for realtime in [false, true] {
                XCTAssertTrue(
                    gpu.processLinearFloat(
                        input: input, output: output, width: side, height: side,
                        stock: stock, options: options, realtime: realtime),
                    "\(stock.name): Metal failed")
                let metal = output.contents().assumingMemoryBound(to: Float.self)

                var ripple = Ripple()
                for level in 0..<Self.levels {
                    let (x, y) = Self.centre(of: level)
                    let i = y * side + x
                    for c in 0..<3 {
                        ripple.add(level,
                                   reference: Self.code(cpu.planes[c][i]),
                                   other: Self.code(metal[i * 4 + c]))
                    }
                }
                ripple.mean /= Double(Self.levels * 3)

                let label = "\(stock.name) "
                    + (realtime ? "realtime" : "reference")
                print(String(
                    format: "RAMP %@ | worst %.4f codes at level %d "
                        + "(print code %.0f) | mean %.4f | print spans %.0f-%.0f",
                    label, ripple.worst, ripple.atLevel, ripple.atCode,
                    ripple.mean, ripple.darkest, ripple.brightest))

                XCTAssertLessThan(
                    ripple.darkest, Self.printMustReachBelow,
                    "\(label): the wedge never gets darker than "
                    + "\(ripple.darkest), so this is not a developed wedge and "
                    + "the agreement below measures nothing")
                XCTAssertGreaterThan(
                    ripple.brightest, Self.printMustReachAbove,
                    "\(label): the wedge never gets brighter than "
                    + "\(ripple.brightest), so this is not a developed wedge "
                    + "and the agreement below measures nothing")
                XCTAssertLessThan(
                    ripple.worst, Self.worstRipple,
                    "\(label): the engines disagree by \(ripple.worst) codes "
                    + "at print code \(ripple.atCode). A worst that sits in "
                    + "the mid-tones and a mean far below it is a ripple, not "
                    + "a shift: something on the print road is being "
                    + "interpolated on a grid too coarse for its own curvature.")
                XCTAssertLessThan(
                    ripple.mean, Self.meanRipple,
                    "\(label): mean difference \(ripple.mean) codes")
            }
        }
    }

    private static let worstRipple = 0.1
    private static let meanRipple = 0.02

    // Require enough output range to prevent a vacuous ripple pass.
    private static let printMustReachBelow = 32.0
    private static let printMustReachAbove = 215.0
}
#endif
