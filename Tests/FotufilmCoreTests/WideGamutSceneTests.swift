import XCTest
@testable import FotufilmCore

final class WideGamutSceneTests: XCTestCase {
    private let luma2020 = SIMD3<Float>(0.2627002, 0.6779981, 0.0593017)
    private let lumaP3 = SIMD3<Float>(0.2289746, 0.6917385, 0.0792869)

    // MARK: - The ingest matrices

    func testSeamMatricesRoundTripExactly() {
        let colors: [SIMD3<Float>] = [
            SIMD3(0.18, 0.18, 0.18), SIMD3(0.9, 0.1, 0.05),
            SIMD3(-0.2, 0.8, 0.7), SIMD3(0.05, -0.1, 1.2),
            SIMD3(2.5, 0.3, -0.04),
        ]
        for rgb in colors {
            let back = ColorScience.linearRec2020ToDisplayP3(
                ColorScience.linearDisplayP3ToRec2020(rgb))
            for channel in 0..<3 {
                XCTAssertEqual(back[channel], rgb[channel], accuracy: 2e-6,
                               "the ingest matrices must be exact inverses")
            }
        }
    }

    func testSeamHoldsTheNeutralAxis() {
        for grey in [Float(0.05), 0.18, 1.0, 4.0] {
            let mapped = ColorScience.linearDisplayP3ToRec2020(
                SIMD3(repeating: grey))
            for channel in 0..<3 {
                XCTAssertEqual(mapped[channel], grey, accuracy: grey * 1e-6 + 1e-7,
                               "P3 white must be 2020 white: rows sum to exactly 1")
            }
        }
    }

    func testLuminanceIsBasisInvariantIncludingNegatives() {
        let colors: [SIMD3<Float>] = [
            SIMD3(0.6, 0.3, 0.1), SIMD3(-0.15, 0.7, 0.9),
            SIMD3(0.02, -0.08, 0.5), SIMD3(1.8, 0.9, -0.1),
        ]
        for rgb in colors {
            let direct = lumaP3.x * rgb.x + lumaP3.y * rgb.y + lumaP3.z * rgb.z
            let wide = ColorScience.linearDisplayP3ToRec2020(rgb)
            let converted = luma2020.x * wide.x + luma2020.y * wide.y
                + luma2020.z * wide.z
            XCTAssertEqual(converted, direct, accuracy: 2e-6,
                           "both weight rows must read the same CIE Y")
        }
    }

    func testSharedConstantsMatchAcrossLanguagesDigitForDigit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func assertContains(_ file: String, _ digits: [String]) throws {
            let source = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for value in digits {
                XCTAssertTrue(source.contains(value),
                              "\(file) lost shared constant digit \(value)")
            }
        }
        let ingest = [
            "0.753833034", "0.198597369", "0.047569597",
            "0.045743849", "0.941777220", "0.012478931",
            "-0.001210340", "0.017601717", "0.983608623",
        ]
        let luma = ["0.2627002", "0.6779981", "0.0593017"]
        try assertContains("Sources/FotufilmHalide/FotufilmHalideShared.h", ingest + luma)
        try assertContains("Sources/FotufilmCore/ColorScience.swift", ingest + luma)
        try assertContains(
            "Sources/FotufilmHalide/FotufilmMetalGrain.mm",
            ["kRecordNeutralWeight = 1.0f / 3.0f"])
    }

    // MARK: - Colour beyond P3 exposes the emulsion

    func testOutOfP3CyanKeepsItsGradient() {
        let stock = TestStocks.negative
        let exposure = SpectralRuntime.tables(for: stock).exposure

        var previous: Float?
        var steps: [Float] = []
        for i in 0...12 {
            // Rec.2020-basis cyan, physical throughout: red falls 0.30 -> 0.06.
            let wide = SIMD3<Float>(0.30 - 0.02 * Float(i), 0.85, 0.85)
            // Mirror recover_exposure: into the table's locus-enclosing basis, where this
            // ramp needs no clamp at all, then the LUT.
            let domain = ColorScience.linearRec2020ToExposureDomain(wide)
            let peak = max(domain.x, max(domain.y, domain.z))
            let sampled = exposure.sample(domain / peak) * peak
            if let previous {
                steps.append(previous - sampled.x)
            }
            previous = sampled.x
        }

        // Strictly decreasing everywhere, including past the P3 edge (index ~5, where
        // transport red crosses zero) — and by a commensurate amount: the smallest step
        // must be a real fraction of the largest, not a numerical remnant of a plateau.
        let largest = steps.max() ?? 0
        XCTAssertGreaterThan(largest, 0, "the ramp must expose the red layer at all")
        for (i, step) in steps.enumerated() {
            XCTAssertGreaterThan(step, largest * 0.05,
                                 "chroma gradient flattened at ramp step \(i + 1) — " +
                                 "out-of-P3 colour is being clipped before the emulsion")
        }
    }

    func testTwoOutOfP3CyansDevelopToDifferentPrints() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        let size = 32
        let simulator = FotufilmEngine(stock: TestStocks.negative, options: options)

        func developedMeans(_ wide: SIMD3<Float>) -> SIMD3<Float> {
            var frame = ImageBuffer(width: size, height: size)
            for i in 0..<(size * size) {
                for c in 0..<3 { frame.planes[c][i] = wide[c] }
            }
            let print = simulator.process(linearRGB: frame)
            var mean = SIMD3<Float>()
            for i in 0..<(size * size) {
                mean += SIMD3(print.planes[0][i], print.planes[1][i],
                              print.planes[2][i])
            }
            return mean / Float(size * size)
        }

        let shallow = developedMeans(SIMD3(0.20, 0.85, 0.85))
        let deep = developedMeans(SIMD3(0.06, 0.85, 0.85))
        XCTAssertLessThan(ColorScience.linearRec2020ToDisplayP3(
            SIMD3(0.20, 0.85, 0.85)).x, 0, "both cyans must lie outside P3")
        // Measured on this model: the red channel of the print separates by ~0.0096
        // display-linear (the deeper cyan prints visibly deeper). Anything under a tenth
        // of that is the plateau this guards against.
        XCTAssertGreaterThan(shallow.x - deep.x, 0.001,
                             "out-of-P3 depth difference vanished in the develop — " +
                             "a clamp is back on the scene path")
    }

    func testP3IngestBarelyGrazesTheWorkingCube() {
        for corner in 0..<8 {
            let p3 = SIMD3<Float>(corner & 1 == 0 ? 0 : 1,
                                  corner & 2 == 0 ? 0 : 1,
                                  corner & 4 == 0 ? 0 : 1)
            let working = ColorScience.linearDisplayP3ToRec2020(p3)
            for channel in 0..<3 {
                XCTAssertGreaterThanOrEqual(
                    working[channel], -0.00122,
                    "P3 corner \(p3) left the working cube beyond the red-primary sliver")
                XCTAssertLessThanOrEqual(
                    working[channel], 1.00122,
                    "P3 corner \(p3) overshot white beyond the mirrored sliver")
            }
            // Only the pure red corner is touched by the clamp; every other corner stays at
            // or above the cube's floor.
            if corner != 1 {
                for channel in 0..<3 {
                    XCTAssertGreaterThanOrEqual(working[channel], -2e-6,
                                                "corner \(p3) should not graze the floor")
                }
            }
        }
        let red = ColorScience.linearDisplayP3ToRec2020(SIMD3(1, 0, 0))
        XCTAssertLessThan(red.z, 0, "P3 red pokes just outside 2020's red–green edge")
        let cyan = ColorScience.linearDisplayP3ToRec2020(SIMD3(0, 1, 1))
        XCTAssertGreaterThan(cyan.z, 1, "the sliver mirrors through the neutral axis")
    }
}
