import XCTest
@testable import FotufilmCore

final class GradeSpaceTests: XCTestCase {
    // MARK: - The transfer the grading space is defined by

    func testTheGradingTransferRoundTripsEverywhere() {
        for value: Float in [0, 0.0005, 0.0031308, 0.05, 0.18, 0.5, 0.9,
                             0.999, 1, 1.0001, 1.5, 3, 4.92] {
            let there = ColorScience.gradingEncode(value)
            let back = ColorScience.gradingDecode(there)
            XCTAssertEqual(back, value, accuracy: max(1e-5, value * 1e-5),
                           "\(value) did not survive the round trip")
        }
    }

    func testTheGradingTransferIsSRGBBelowWhite() {
        for value: Float in [0.002, 0.05, 0.18, 0.5, 0.9, 0.999] {
            XCTAssertEqual(ColorScience.gradingEncode(value),
                           ColorScience.linearToSrgb(value), accuracy: 1e-6)
        }
    }

    func testTheGradingTransferMeetsWhiteSmoothly() {
        XCTAssertEqual(ColorScience.gradingEncode(1), 1, accuracy: 1e-6)
        let step: Float = 1e-3
        let below = (ColorScience.gradingEncode(1)
                     - ColorScience.gradingEncode(1 - step)) / step
        let above = (ColorScience.gradingEncode(1 + step)
                     - ColorScience.gradingEncode(1)) / step
        XCTAssertEqual(below, above, accuracy: 1e-3)
        XCTAssertEqual(above, ColorScience.srgbSlopeAtWhite, accuracy: 1e-3)
    }

    // MARK: - What the space means for the grade

    func testLinearIsTheDefault() {
        XCTAssertEqual(FotufilmEngine.Options().gradeSpace, .linear)
    }

    func testANeutralGradeIsTheIdentityInBothSpaces() {
        for value: Float in [0, 0.02, 0.18, 0.75, 1, 2.5, 4.92] {
            let triple = SIMD3<Float>(repeating: value)
            for space: ColorGrade.Space in [.linear, .encoded] {
                let out = ColorGrade.neutral.apply(triple, in: space)
                XCTAssertEqual(out.x, value, accuracy: max(1e-5, value * 1e-5),
                               "\(space) moved an untouched \(value)")
            }
        }
    }

    func testTheMidtoneBandIsAPowerOnTheEncodedSignal() {
        var grade = ColorGrade.neutral
        grade.midtones.level = 0.7
        let exponent = grade.inverseGamma.x
        XCTAssertNotEqual(exponent, 1, accuracy: 1e-6)

        for value: Float in [0.05, 0.18, 0.5, 0.85] {
            let expected = ColorScience.gradingDecode(
                pow(ColorScience.gradingEncode(value), exponent))
            let actual = grade.apply(SIMD3(repeating: value), in: .encoded).x
            XCTAssertEqual(actual, expected, accuracy: 1e-5)
        }
    }

    func testTheHighlightBandIsWhereTheSpacesPartCompany() {
        var grade = ColorGrade.neutral
        grade.highlights.level = 1
        for value: Float in [0.02, 0.18, 0.5] {
            let linear = grade.apply(SIMD3(repeating: value), in: .linear).x
            let encoded = grade.apply(SIMD3(repeating: value), in: .encoded).x
            XCTAssertGreaterThan(encoded / linear, 1.4,
                                 "at \(value): linear \(linear), encoded \(encoded)")
        }
    }

    func testTheShadowBandPartsCompanyOnlyInTheDeepShadows() {
        var grade = ColorGrade.neutral
        grade.shadows.level = 1
        let deepLinear = grade.apply(SIMD3(repeating: 0.001), in: .linear).x
        let deepEncoded = grade.apply(SIMD3(repeating: 0.001), in: .encoded).x
        XCTAssertGreaterThan(deepLinear / deepEncoded, 5,
                             "linear \(deepLinear) vs encoded \(deepEncoded)")

        let midLinear = grade.apply(SIMD3(repeating: 0.5), in: .linear).x
        let midEncoded = grade.apply(SIMD3(repeating: 0.5), in: .encoded).x
        XCTAssertEqual(midEncoded, midLinear, accuracy: midLinear * 0.02)
    }

    func testAMidtoneMoveMeansNearlyTheSameInEitherSpace() {
        var grade = ColorGrade.neutral
        grade.midtones.level = 0.7
        for value: Float in [0.05, 0.18, 0.5, 0.9] {
            let linear = grade.apply(SIMD3(repeating: value), in: .linear).x
            let encoded = grade.apply(SIMD3(repeating: value), in: .encoded).x
            XCTAssertEqual(encoded, linear, accuracy: linear * 0.05,
                           "at \(value)")
        }
    }

    func testLightAboveWhiteSurvivesAnEncodedGrade() {
        var grade = ColorGrade.neutral
        grade.highlights.level = 0.5
        let out = grade.apply(SIMD3(repeating: 3), in: .encoded).x
        XCTAssertGreaterThan(out, 1.5,
                             "above-white light collapsed to \(out)")
    }
}

final class GradeSpaceKernelTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide engine required")
    }

    private func uniform(_ level: UInt8, size: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4] = level
            pixels[i * 4 + 1] = level
            pixels[i * 4 + 2] = level
        }
        return pixels
    }

    private func render(_ grade: ColorGrade, space: ColorGrade.Space,
                        stock: FilmStock, level: UInt8,
                        size: Int = 32) -> [UInt8] {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.grade = grade
        options.gradeSpace = space
        return FotufilmEngine(stock: stock, options: options)
            .processSRGB8(uniform(level, size: size), width: size, height: size)
    }

    private func green(_ pixels: [UInt8]) -> Double {
        let count = pixels.count / 4
        var sum = 0.0
        for i in 0..<count { sum += Double(pixels[i * 4 + 1]) }
        return sum / Double(count)
    }

    func testTheSwitchOffLeavesEveryRenderByteIdentical() {
        var grade = ColorGrade.neutral
        grade.shadows = .init(balanceX: -0.5, balanceY: 0.3, level: 0.6)
        grade.midtones.level = -0.5
        grade.highlights = .init(balanceX: 0.4, balanceY: 0, level: 0.8)
        for stock in TestStocks.all {
            for level: UInt8 in [16, 96, 200, 245] {
                var untouched = FotufilmEngine.Options()
                untouched.grainScale = 0
                untouched.grade = grade
                let before = FotufilmEngine(stock: stock, options: untouched)
                    .processSRGB8(uniform(level, size: 32), width: 32, height: 32)
                let after = render(grade, space: .linear, stock: stock,
                                   level: level)
                XCTAssertEqual(before, after,
                               "\(stock.name) at \(level) moved with the switch off")
            }
        }
    }

    func testANeutralGradeIsIdenticalInBothSpacesThroughTheKernel() {
        for stock in TestStocks.all {
            for level: UInt8 in [16, 96, 200, 250, 255] {
                let linear = render(.neutral, space: .linear, stock: stock,
                                    level: level)
                let encoded = render(.neutral, space: .encoded, stock: stock,
                                     level: level)
                XCTAssertEqual(green(linear), green(encoded), accuracy: 1,
                               "\(stock.name) at \(level) moved under a neutral grade")
            }
        }
    }

    func testTheKernelMatchesTheSwiftReference() throws {
        let stock = TestStocks.negative
        var grade = ColorGrade.neutral
        grade.midtones.level = 0.6
        grade.shadows.level = 0.4
        grade.highlights.level = -0.3

        for level: UInt8 in [32, 96, 160] {
            let ungraded = green(render(.neutral, space: .linear, stock: stock,
                                        level: level)) / 255
            try XCTSkipIf(ungraded > 0.94,
                          "level \(level) prints into the shoulder")
            let printLinear = ColorScience.srgbToLinear(Float(ungraded))
            let expected = ColorScience.linearToSrgb(
                grade.apply(SIMD3(repeating: printLinear), in: .encoded).y) * 255
            let actual = green(render(grade, space: .encoded, stock: stock,
                                      level: level))
            // One code value of slack for the engine's own 8-bit rounding at each end.
            XCTAssertEqual(actual, Double(expected), accuracy: 2,
                           "level \(level): kernel \(actual), Swift \(expected)")
        }
    }
}
