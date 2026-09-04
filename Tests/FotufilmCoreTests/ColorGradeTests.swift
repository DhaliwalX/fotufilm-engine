import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class ColorGradeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide engine required")
    }

    private func uniformSRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8,
                             size: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4] = r; pixels[i * 4 + 1] = g; pixels[i * 4 + 2] = b
            pixels[i * 4 + 3] = 255
        }
        return pixels
    }

    private func channelMeans(_ pixels: [UInt8]) -> (Double, Double, Double) {
        var sums = (0.0, 0.0, 0.0)
        let count = pixels.count / 4
        for i in 0..<count {
            sums.0 += Double(pixels[i * 4])
            sums.1 += Double(pixels[i * 4 + 1])
            sums.2 += Double(pixels[i * 4 + 2])
        }
        return (sums.0 / Double(count), sums.1 / Double(count),
                sums.2 / Double(count))
    }

    private func render(_ grade: ColorGrade, _ stock: FilmStock,
                        level: UInt8, size: Int = 48) -> [UInt8] {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.grade = grade
        return FotufilmEngine(stock: stock, options: options)
            .processSRGB8(uniformSRGB(level, level, level, size: size),
                          width: size, height: size)
    }

    func testNeutralGradePacksTheExactIdentity() {
        let neutral = ColorGrade.neutral
        XCTAssertEqual(neutral.packed, [0, 0, 0, 1, 1, 1, 1, 1, 1])
        XCTAssertTrue(neutral.isNeutral)
    }

    func testTheGradeSurvivesBeingSavedAndRead() throws {
        var grade = ColorGrade.neutral
        grade.shadows = .init(balanceX: -0.4, balanceY: 0.25, level: 0.6)
        grade.highlights = .init(balanceX: 0.9, balanceY: -0.1, level: -0.2)
        let data = try JSONEncoder().encode(grade)
        XCTAssertEqual(try JSONDecoder().decode(ColorGrade.self, from: data),
                       grade)

        let empty = try JSONDecoder().decode(ColorGrade.self,
                                             from: Data("{}".utf8))
        XCTAssertTrue(empty.isNeutral)
    }

    func testNeutralGradeLeavesTheRenderByteIdentical() {
        var ungraded = FotufilmEngine.Options()
        ungraded.grainScale = 0
        for stock in TestStocks.all {
            for level: UInt8 in [16, 64, 128, 200, 245] {
                let size = 48
                let input = uniformSRGB(level, level, level, size: size)
                let plain = FotufilmEngine(stock: stock, options: ungraded)
                    .processSRGB8(input, width: size, height: size)
                let graded = render(.neutral, stock, level: level, size: size)
                XCTAssertEqual(plain, graded,
                               "\(stock.name) at \(level) moved under a neutral grade")
            }
        }
    }

    func testEachBandMovesItsOwnEndOfTheToneScale() {
        let stock = TestStocks.negative
        let black: UInt8 = 8, white: UInt8 = 245
        let blackBase = channelMeans(render(.neutral, stock, level: black)).1
        let whiteBase = channelMeans(render(.neutral, stock, level: white)).1

        var lifted = ColorGrade.neutral
        lifted.shadows.level = 1
        let liftedBlack = channelMeans(render(lifted, stock, level: black)).1 - blackBase
        let liftedWhite = channelMeans(render(lifted, stock, level: white)).1 - whiteBase
        XCTAssertGreaterThan(liftedBlack, 15, "a full lift should open the blacks")
        XCTAssertGreaterThan(liftedBlack, 8 * liftedWhite,
                             "a lift should be a shadow control: black moved \(liftedBlack), white \(liftedWhite)")

        var gained = ColorGrade.neutral
        gained.highlights.level = 1
        let gainedWhite = channelMeans(render(gained, stock, level: white)).1 - whiteBase
        let gainedBlack = channelMeans(render(gained, stock, level: black)).1 - blackBase
        XCTAssertGreaterThan(gainedWhite, 12, "a full gain should carry white up")
        // The measured sheet turns over at 2.10 D, limiting gain above diffuse white. Compare gain
        // with lift so the assertion tests band separation independently of paper range.
        XCTAssertGreaterThan(gainedWhite, 1.8 * gainedBlack,
                             "a gain should be a highlight control: white moved \(gainedWhite), black \(gainedBlack)")
        XCTAssertGreaterThan(gainedWhite, liftedWhite,
                             "the gain must own the whites: \(gainedWhite) against \(liftedWhite)")
        XCTAssertGreaterThan(liftedBlack, gainedBlack,
                             "the lift must own the blacks: \(liftedBlack) against \(gainedBlack)")

        var midUp = ColorGrade.neutral, midDown = ColorGrade.neutral
        midUp.midtones.level = 1
        midDown.midtones.level = -1
        let mid = channelMeans(render(.neutral, stock, level: 128)).1
        XCTAssertGreaterThan(channelMeans(render(midUp, stock, level: 128)).1, mid + 10)
        XCTAssertLessThan(channelMeans(render(midDown, stock, level: 128)).1, mid - 10)
    }

    func testThePadTiltsTheColourItsWashPromises() {
        let stock = TestStocks.negative
        let base = channelMeans(render(.neutral, stock, level: 200))

        var warm = ColorGrade.neutral
        warm.highlights.balanceX = 1
        let warmed = channelMeans(render(warm, stock, level: 200))
        XCTAssertGreaterThan(warmed.0 - base.0, base.2 - warmed.2 - 1,
                             "warm should raise red")
        XCTAssertLessThan(warmed.2, base.2, "warm should lower blue")

        var green = ColorGrade.neutral
        green.highlights.balanceY = 1
        let greened = channelMeans(render(green, stock, level: 200))
        XCTAssertGreaterThan(greened.1, base.1, "up should raise green")
        XCTAssertLessThan(greened.0, base.0, "up should lower red")
        XCTAssertLessThan(greened.2, base.2, "up should lower blue")
    }

    func testThePadHoldsItsLevelWhileItTiltsColour() {
        for band in [\ColorGrade.shadows, \ColorGrade.midtones,
                     \ColorGrade.highlights] as [WritableKeyPath<ColorGrade, ColorGrade.Band>] {
            var tilted = ColorGrade.neutral
            tilted[keyPath: band].balanceX = 1
            let sum = tilted[keyPath: band].tilt.x + tilted[keyPath: band].tilt.y
                + tilted[keyPath: band].tilt.z
            XCTAssertEqual(sum, 0, accuracy: 1e-6)
            var vertical = ColorGrade.neutral
            vertical[keyPath: band].balanceY = 1
            let verticalSum = vertical[keyPath: band].tilt.x
                + vertical[keyPath: band].tilt.y + vertical[keyPath: band].tilt.z
            XCTAssertEqual(verticalSum, 0, accuracy: 1e-6)
        }
    }

    func testAMonochromeStockCanStillBeToned() {
        var warm = ColorGrade.neutral
        warm.midtones.balanceX = 1
        let plain = channelMeans(render(.neutral, TestStocks.monochrome, level: 140))
        let toned = channelMeans(render(warm, TestStocks.monochrome, level: 140))
        XCTAssertEqual(plain.0, plain.2, accuracy: 1.0,
                       "an ungraded monochrome print is neutral")
        XCTAssertGreaterThan(toned.0 - toned.2, 6.0,
                             "a warm grade should separate red from blue on a B&W print")
    }

#if canImport(Metal)
    func testTheFrameScheduleGradesLikeTheStillOne() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else {
            throw XCTSkip("Halide Metal unavailable")
        }
        var grade = ColorGrade.neutral
        grade.shadows = .init(balanceX: -0.7, balanceY: 0.2, level: 0.5)
        grade.midtones = .init(balanceX: 0.3, balanceY: -0.4, level: -0.3)
        grade.highlights = .init(balanceX: 0.8, balanceY: 0.1, level: 0.6)

        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.grade = grade
        let size = 64
        for stock in TestStocks.all {
            for level: UInt8 in [16, 64, 128, 200, 245] {
                let input = uniformSRGB(level, level, level, size: size)
                let cpu = FotufilmEngine(stock: stock, options: options)
                    .processSRGB8(input, width: size, height: size)
                let frame = try XCTUnwrap(
                    gpu.processSRGB8(input, width: size, height: size,
                                     stock: stock, options: options))
                let (cr, cg, cb) = channelMeans(cpu)
                let (fr, fg, fb) = channelMeans(frame)
                for (c, f) in [(cr, fr), (cg, fg), (cb, fb)] {
                    XCTAssertEqual(c, f, accuracy: 2.0,
                                   "\(stock.name) at \(level): still \(c) vs frame \(f)")
                }
            }
        }
    }
#endif
}
