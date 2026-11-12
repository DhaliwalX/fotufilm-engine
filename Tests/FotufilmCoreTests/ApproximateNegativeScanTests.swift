import XCTest
@testable import FotufilmCore

final class ApproximateNegativeScanTests: XCTestCase {
    func testRestoresBaseAndExcludesHolderWithoutChangingOtherPixels() throws {
        let stock = TestStocks.negative
        let border = SIMD3<Float>(0.4, 0.6, 0.2)
        let plan = try ApproximateNegativeScan(stock: stock, border: border)
        let image = ImageBuffer(width: 4, height: 1, planes: [
            [0.4, 0.04, 0, .nan], [0.6, 0.06, 0.2, 0.1], [0.2, 0.02, 0.1, 0.1]])
        let result = try plan.convert(image)
        XCTAssertEqual(result.invalid, [false, false, true, true])
        for channel in 0..<3 {
            XCTAssertEqual(result.density.planes[channel][0], stock.curves[channel].dMin, accuracy: 0.000001)
            XCTAssertEqual(result.density.planes[channel][1], stock.curves[channel].dMin + 1, accuracy: 0.000001)
            XCTAssertEqual(result.density.planes[channel][2], stock.curves[channel].dMin, accuracy: 0.000001)
        }
        XCTAssertEqual(image.planes[0][2], 0)
        XCTAssertTrue(image.planes[0][3].isNaN)
    }
    func testReferenceAndDimensionsAreValidated() throws {
        XCTAssertThrowsError(try ApproximateNegativeScan(stock: TestStocks.negative, border: .zero))
        XCTAssertThrowsError(try ApproximateNegativeScan(stock: TestStocks.negative, border: SIMD3(1, .infinity, 1)))
        let plan = try ApproximateNegativeScan(stock: TestStocks.negative, border: SIMD3(repeating: 1))
        var malformed = ImageBuffer(width: 2, height: 1)
        malformed.planes[0] = [1]
        XCTAssertThrowsError(try plan.convert(malformed))
    }

    /// A balance moves each record along the film's own curve: nothing at the clear film, one
    /// density on the straight line, and what counts as film stays where it was.
    func testABalanceMovesARecordAlongItsCurveAndNotTheFilmsRange() throws {
        let stock = TestStocks.negative
        let border = SIMD3<Float>(0.4, 0.6, 0.2)
        let plain = try ApproximateNegativeScan(stock: stock, border: border)
        XCTAssertEqual(plain.balance, [[Float]](
            repeating: [Float](repeating: 0, count: ApproximateNegativeScan.balanceSamples),
            count: 3))
        let exposure = SIMD3<Float>(0.2, 0, -0.3)
        let moved = try ApproximateNegativeScan(stock: stock, border: border, exposure: exposure)
        XCTAssertEqual(moved.minimumSample, plain.minimumSample)
        XCTAssertEqual(moved.maximumSample, plain.maximumSample)
        XCTAssertEqual(moved.baseDensity, plain.baseDensity)
        XCTAssertEqual(moved.balance[1], plain.balance[1])
        // The clear film is the film's base whatever the balance.
        XCTAssertEqual(try XCTUnwrap(moved.density(of: border)),
                       try XCTUnwrap(plain.density(of: border)))
        for sample in [SIMD3<Float>(0.3, 0.45, 0.15), SIMD3(0.12, 0.18, 0.06),
                       SIMD3(0.04, 0.06, 0.02), SIMD3(0.1, 0.3, 0.004)] {
            let read = try XCTUnwrap(moved.density(of: sample))
            let unmoved = try XCTUnwrap(plain.density(of: sample))
            XCTAssertEqual(read.y, unmoved.y)
            for record in [0, 2] {
                // The density the film's curve gives the exposure that made the reading, moved.
                let curve = stock.curves[record]
                let made = curve.logExposure(density: unmoved[record])
                XCTAssertEqual(read[record], curve.density(logExposure: made + exposure[record]),
                               accuracy: 0.004, "\(sample) \(record)")
                XCTAssertEqual(read[record] > unmoved[record], exposure[record] > 0)
            }
        }
        // More exposure moves a dense record further than a thin one, up to the curve's slope.
        let thin = try XCTUnwrap(moved.density(of: SIMD3(0.3, 0.45, 0.15))).x
            - (try XCTUnwrap(plain.density(of: SIMD3(0.3, 0.45, 0.15))).x)
        let dense = try XCTUnwrap(moved.density(of: SIMD3(0.04, 0.06, 0.02))).x
            - (try XCTUnwrap(plain.density(of: SIMD3(0.04, 0.06, 0.02))).x)
        XCTAssertGreaterThan(dense, thin)
        XCTAssertEqual(dense, stock.curves[0].gamma * exposure.x, accuracy: 0.02)
        for invalid in [SIMD3<Float>(.nan, 0, 0), SIMD3(0, 1.6, 0), SIMD3(0, 0, -1.6)] {
            XCTAssertThrowsError(try ApproximateNegativeScan(stock: stock, border: border,
                                                             exposure: invalid))
        }
        // A black-and-white film has one record and nothing to balance.
        let monochrome = try XCTUnwrap(FilmStock.presetDefinitions["hp5plus400"]).validated().stock
        XCTAssertEqual(
            try ApproximateNegativeScan(stock: monochrome, border: border, exposure: exposure),
            try ApproximateNegativeScan(stock: monochrome, border: border))
    }

    /// Stray light lifts every sample alike, which reads a dense highlight thinner than it is.
    /// Taken off the sample and the clear film before their densities, the film reads as it is.
    func testFlareIsTakenOffBeforeADensityIsRead() throws {
        let stock = TestStocks.negative
        let border = SIMD3<Float>(0.4, 0.6, 0.2)
        let plain = try ApproximateNegativeScan(stock: stock, border: border)
        let flare = SIMD3<Float>(0.002, 0.003, 0.001)
        let cleaned = try ApproximateNegativeScan(stock: stock, border: border + flare,
                                                  flare: flare)
        XCTAssertEqual(cleaned.flare, [0.002, 0.003, 0.001])
        for density in [Float(0), 0.5, 1.5, 2.5] {
            let film = border * pow(10, -density)
            let read = try XCTUnwrap(cleaned.density(of: film + flare))
            let expected = try XCTUnwrap(plain.density(of: film))
            let lifted = try XCTUnwrap(plain.density(of: film + flare))
            for record in 0..<3 {
                XCTAssertEqual(read[record], expected[record], accuracy: 2e-4)
                // Left in, a hundredth of the clear film's light costs the densest film most.
                if density >= 1.5 {
                    XCTAssertLessThan(lifted[record], expected[record] - 0.05 * (density - 1))
                }
            }
        }
        // A sample at the stray light's level or under it shows no film.
        XCTAssertNil(cleaned.density(of: flare))
        XCTAssertNil(cleaned.density(of: flare * 0.5))
        // Stray light is no more than half the clear film's, and never less than none.
        for invalid in [SIMD3<Float>(-0.001, 0, 0), SIMD3(0, .nan, 0), SIMD3(0.21, 0, 0)] {
            XCTAssertThrowsError(try ApproximateNegativeScan(stock: stock, border: border,
                                                             flare: invalid))
        }
    }

    /// A scan that shows its bare light past the film, through sprocket holes or around a
    /// strip: the film's base is the orange plateau under the light, not the light.
    func testTheEstimatedFilmBaseIsUnderABareLightTheScanShows() throws {
        let lamp = SIMD3<Float>(0.82, 0.8, 0.84), mask = SIMD3<Float>(0.35, 0.7, 0.95)
        let base = SIMD3((0..<3).map { lamp[$0] * pow(10, -mask[$0]) })
        let width = 120, height = 80
        func scan(holes: Bool) -> ImageBuffer {
            var image = ImageBuffer(width: width, height: height)
            for y in 0..<height { for x in 0..<width {
                let i = y * width + x
                let rebate = y < 10 || y >= 70
                let hole = holes && rebate && x % 20 < 6 && (y < 6 || y >= 74)
                let density = 0.2 + 1.4 * Float(x) / Float(width)
                for c in 0..<3 {
                    image.planes[c][i] = hole ? lamp[c] : rebate ? base[c]
                        : base[c] * pow(10, -density * (0.9 + 0.1 * Float(c)))
                }
            } }
            return image
        }
        let shown = scan(holes: true)
        // The brightest of the scan is the light through the holes.
        let brightest = try XCTUnwrap(ApproximateNegativeScan.estimatedBorder(preview: shown))
        let found = try XCTUnwrap(ApproximateNegativeScan.estimatedFilmBase(preview: shown))
        for c in 0..<3 {
            XCTAssertEqual(brightest[c], lamp[c], accuracy: 1e-4)
            XCTAssertEqual(found[c], base[c], accuracy: 1e-4)
        }
        // A scan balanced on its clear film shows that film neutral. An orange plateau under it
        // is then a picture's own tone, a dense sky, with most of the scan brighter than it:
        // not a base under a light.
        var balanced = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            let sky = y >= 12 && y < 40
            for c in 0..<3 {
                balanced.planes[c][i] = y < 12 ? lamp[c]
                    : sky ? base[c] : lamp[c] * pow(10, -(0.15 + 0.6 * Float(x) / Float(width)))
            }
        } }
        XCTAssertEqual(ApproximateNegativeScan.estimatedFilmBase(preview: balanced),
                       ApproximateNegativeScan.estimatedBorder(preview: balanced))
        // With no light showing, both are the film's rebate.
        let plain = scan(holes: false)
        XCTAssertEqual(ApproximateNegativeScan.estimatedFilmBase(preview: plain),
                       ApproximateNegativeScan.estimatedBorder(preview: plain))
        XCTAssertNil(ApproximateNegativeScan.estimatedFilmBase(preview: ImageBuffer(width: 2, height: 2)))
    }

    func testMonochromeUsesGreenForEveryFilmRecord() throws {
        let stock = try XCTUnwrap(FilmStock.presetDefinitions["hp5plus400"]).validated().stock
        let plan = try ApproximateNegativeScan(stock: stock, border: SIMD3(0.4, 0.6, 0.2))
        let scan = ImageBuffer(width: 2, height: 1, planes: [[0.004, 0], [0.06, 0.06], [0.02, 0.02]])
        let result = try plan.convert(scan)
        XCTAssertEqual(result.invalid, [false, true])
        for c in 0..<3 {
            XCTAssertEqual(result.density.planes[c][0], stock.curves[c].dMin + 1, accuracy: 0.000001)
            XCTAssertEqual(result.density.planes[c][1], stock.curves[c].dMin, accuracy: 0.000001)
        }
    }
}
