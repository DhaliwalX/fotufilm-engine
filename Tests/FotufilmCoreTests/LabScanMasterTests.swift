import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class LabScanMasterTests: XCTestCase {
    func testReceiverCurveKeepsSeparationAtBothEnds() {
        let curve = PrintPaper.labScanCurve
        var previous = curve.density(logExposure: -4)
        XCTAssertGreaterThan(previous, curve.dMin)
        for x in stride(from: Float(-3.95), through: 2, by: 0.05) {
            let density = curve.density(logExposure: x)
            XCTAssertGreaterThan(density, previous, "receiver exposure \(x)")
            XCTAssertLessThan(density, curve.dMax)
            previous = density
        }
    }

    func testGamutCompressionPreservesLuminanceAndColorDirection() {
        let w = ColorScience.displayP3LuminanceWeights
        for color: SIMD3<Float> in [SIMD3(-0.1, 0.2, 1.2), SIMD3(1.4, 0.8, 0.3),
                                    SIMD3(0.2, 0.4, 0.5), SIMD3(repeating: 0.18)] {
            let y = color.x * w.0 + color.y * w.1 + color.z * w.2
            let result = SpectralRuntime.compressedToDisplayGamut(color, luminance: y)
            XCTAssertEqual(result.x * w.0 + result.y * w.1 + result.z * w.2, y,
                           accuracy: 2e-6)
            for c in 0..<3 { XCTAssertGreaterThan(result[c], 0); XCTAssertLessThan(result[c], 1) }
            let before = color - SIMD3(repeating: y), after = result - SIMD3(repeating: y)
            XCTAssertEqual(before.x * after.y, before.y * after.x, accuracy: 2e-6)
            XCTAssertEqual(before.x * after.z, before.z * after.x, accuracy: 2e-6)
            if color == SIMD3(repeating: 0.18) { XCTAssertEqual(result, color) }
        }
    }

    private let stops: [Float] = [-8, -6, -4, 0, 4, 6, 8, 10, 12]

    private func ramp() -> ImageBuffer {
        let width = stops.count * 8
        var image = ImageBuffer(width: width, height: 24)
        for y in 0..<24 { for x in 0..<width {
            let level = 0.18 * pow(2, stops[x / 8])
            let color: SIMD3<Float> = y < 8 ? SIMD3(repeating: 1)
                : y < 16 ? SIMD3(0.02, 0.05, 1) : SIMD3(1, 0.9, 0.02)
            let scene = ColorScience.linearSRGBToRec2020(color) * level
            for c in 0..<3 { image.planes[c][y * width + x] = scene[c] }
        }}
        return image
    }

    private var options: FotufilmEngine.Options {
        var value = FotufilmEngine.Options()
        value.paper = .labScan; value.grainScale = 0; value.halationScale = 0
        value.flareScale = 0; value.couplerScale = 0; value.localTone = false
        return value
    }

    private func stock(_ id: String) throws -> FilmStock {
        var film = try XCTUnwrap(FilmStock.named(id), id)
        film.emulsionDiffusionMM = [0, 0, 0]; film.emulsionDiffusionSecondaryMM = [0, 0, 0]
        film.adjacencyStrength = 0
        return film
    }

    func testRenderedScanRetainsShadowAndHighlightStepsForSixteenBitDelivery() throws {
        let input = ramp()
        for id in ["portra400", "vision500t", "hp5plus400"] {
            let output = try FotufilmEngine(stock: stock(id), options: options)
                .processChecked(linearRGB: input)
            var codes: [Float] = []
            for column in stops.indices {
                let i = 4 * input.width + column * 8 + 4
                let y = output.planes[0][i] * 0.2289746
                    + output.planes[1][i] * 0.6917385 + output.planes[2][i] * 0.0792869
                XCTAssertGreaterThan(y, 0, id); XCTAssertLessThan(y, 1, id)
                codes.append(ColorScience.linearToSrgb(ColorScience.displayShoulder(
                    y, knee: FilmSDRDelivery.boundedShoulderKnee)) * 65535)
            }
            // A two-stop change must remain distinct after integer delivery where the old scan
            // had already reached white, and in the shadow interval approaching its film toe.
            for pair in [(1, 2), (4, 5), (5, 6)] {
                XCTAssertGreaterThan(codes[pair.1] - codes[pair.0], 2,
                                     "\(id), \(stops[pair.0]) to \(stops[pair.1]) EV")
            }
            for plane in output.planes { for v in plane {
                XCTAssertTrue(v.isFinite); XCTAssertGreaterThanOrEqual(v, 0)
                XCTAssertLessThanOrEqual(v, 1)
            }}
        }
    }

    func testNeutralShadowsStayNeutralAtTheFilmsBlackFloor() throws {
        let input = ramp()
        var film = TestStocks.negative
        film.emulsionDiffusionMM = [0, 0, 0]
        film.emulsionDiffusionSecondaryMM = [0, 0, 0]
        film.adjacencyStrength = 0
        let output = try FotufilmEngine(stock: film, options: options)
            .processChecked(linearRGB: input)
        for column in 0..<2 {
            let i = 4 * input.width + column * 8 + 4
            let rgb = (0..<3).map { output.planes[$0][i] }
            XCTAssertEqual(rgb.max()!, rgb.min()!, accuracy: 2e-5,
                           "neutral toe gained false color at \(stops[column]) EV: \(rgb)")
        }
        let dark = output.planes[1][4 * input.width + 12]
        let brighter = output.planes[1][4 * input.width + 20]
        XCTAssertGreaterThan(brighter, dark, "neutralizing color must retain shadow detail")
    }

    #if canImport(Metal)
    func testScanRampAgreesOnCPUAndMetal() throws {
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let input = ramp()
        let rgba = (0..<input.pixelCount).flatMap { i in
            [input.planes[0][i], input.planes[1][i], input.planes[2][i], Float(1)]
        }
        for id in ["portra400", "vision500t", "hp5plus400"] {
            let film = try stock(id)
            let cpu = try FotufilmEngine(stock: film, options: options).processChecked(linearRGB: input)
            let metal = try XCTUnwrap(gpu.processLinearFloat(rgba, width: input.width,
                height: input.height, stock: film, options: options))
            for i in 0..<input.pixelCount { for c in 0..<3 {
                XCTAssertEqual(cpu.planes[c][i], metal[4 * i + c], accuracy: 2e-4, id)
            }}
        }
    }
    #endif
}
