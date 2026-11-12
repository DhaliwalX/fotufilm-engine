import XCTest
@testable import FotufilmCore

/// A frame's tonal steps say how steep its records read against each other.
final class NegativeScanContrastTests: XCTestCase {
    private let border = SIMD3<Float>(0.5, 0.25, 0.12)

    /// A picture of square patches, each a tone on one surface colour: `tone` the green density
    /// over the border and `colour` what the surface adds to red and blue.
    private func preview(width: Int = 120, height: Int = 90, slopes: SIMD2<Float>,
                         tone: (Int, Int) -> Float,
                         colour: (Int, Int) -> SIMD2<Float> = { _, _ in .zero }) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let green = tone(x / 6, y / 6), surface = colour(x / 18, y / 18)
            let density = SIMD3(slopes.x * green + surface.x, green, slopes.y * green + surface.y)
            for c in 0..<3 { image.planes[c][y * width + x] = border[c] * pow(10, -density[c]) }
        } }
        return image
    }

    /// Tones that differ from patch to patch, the same every run.
    private func tone(_ x: Int, _ y: Int) -> Float {
        0.3 + 0.2 * Float((x * 7 + y * 13 + (x * y) % 5) % 6)
    }

    func testTonalStepsGiveTheRisesOfRedAndBlueAgainstGreen() throws {
        let slopes = SIMD2<Float>(0.62, 1.15)
        let found = try XCTUnwrap(ApproximateNegativeScan.tonalSlopes(
            border: border, preview: preview(slopes: slopes, tone: tone)))
        XCTAssertEqual(found.x, slopes.x, accuracy: 1e-4)
        XCTAssertEqual(found.y, slopes.y, accuracy: 1e-4)
    }

    func testSurfaceColoursScatterTheStepsWithoutMovingTheirMiddle() throws {
        let slopes = SIMD2<Float>(0.62, 1.15)
        // Surfaces three patches wide, each its own colour: most steps lie inside one.
        let colour = { (x: Int, y: Int) -> SIMD2<Float> in
            SIMD2(0.12 * Float((x * 5 + y * 3) % 5 - 2) / 2, 0.15 * Float((x * 3 + y * 7) % 5 - 2) / 2)
        }
        let found = try XCTUnwrap(ApproximateNegativeScan.tonalSlopes(
            border: border, preview: preview(slopes: slopes, tone: tone, colour: colour)))
        XCTAssertEqual(found.x, slopes.x, accuracy: 0.01)
        XCTAssertEqual(found.y, slopes.y, accuracy: 0.01)
        // A cast over the whole frame is a level, which steps do not see.
        let cast = try XCTUnwrap(ApproximateNegativeScan.tonalSlopes(
            border: border,
            preview: preview(slopes: slopes, tone: tone, colour: { _, _ in SIMD2(0.2, -0.3) })))
        XCTAssertEqual(cast.x, slopes.x, accuracy: 1e-4)
        XCTAssertEqual(cast.y, slopes.y, accuracy: 1e-4)
    }

    func testAFrameWithoutStepsTellsNothing() {
        let slopes = SIMD2<Float>(0.62, 1.15)
        let flat = preview(slopes: slopes, tone: { x, _ in 0.8 + 0.01 * Float(x % 3) })
        XCTAssertNil(ApproximateNegativeScan.tonalSlopes(border: border, preview: flat))
        XCTAssertNil(ApproximateNegativeScan.tonalSlopes(
            border: border, preview: preview(width: 1, height: 1, slopes: slopes, tone: tone)))
        XCTAssertNil(ApproximateNegativeScan.tonalSlopes(
            border: SIMD3(0.5, 0, 0.12), preview: preview(slopes: slopes, tone: tone)))
        // Pixels that pass no light are left out, and the rest still tell.
        var holed = preview(slopes: slopes, tone: tone)
        for i in stride(from: 0, to: holed.pixelCount, by: 7) { holed.planes[1][i] = 0 }
        let found = ApproximateNegativeScan.tonalSlopes(border: border, preview: holed)
        XCTAssertEqual(found?.x ?? 0, slopes.x, accuracy: 1e-4)
    }

    private func stock(_ id: String) throws -> FilmStock {
        try XCTUnwrap(FilmStock.presetDefinitions[id]).validated().stock
    }

    private let setup = NegativeScanSetup(light: .white, camera: .profile("sony-ilce-7cm2"))

    /// A roll developed off the film's own contrast: red 0.8 times as steep and blue 1.1 times,
    /// as `steepness`. Its frames show patches of surfaces of several colours under light that
    /// falls off across them; the scan model gives what the camera sees of each.
    private func frame(_ stock: FilmStock, _ model: NegativeScanModel, steepness: SIMD3<Float>,
                       seed: Int) -> ImageBuffer {
        var image = ImageBuffer(width: 120, height: 90)
        for py in 0..<15 { for px in 0..<20 {
            let exposure = -1.1 + 0.3 * Float((px * 7 + py * 13 + seed + (px * py) % 5) % 6)
            let surface = (px / 3 * 5 + py / 3 * 3 + seed) % 5
            let shift = SIMD3<Float>(0.1 * Float(surface - 2), 0, -0.12 * Float((surface * 2) % 5 - 2))
            let film = NegativeScanModel.density(stock: stock, logExposure: exposure, shift: shift)
            let developed = (0..<3).map {
                stock.curves[$0].dMin + steepness[$0] * (film[$0] - stock.curves[$0].dMin)
            }
            let sample = model.sample(density: developed)
            for y in (py * 6)..<(py * 6 + 6) { for x in (px * 6)..<(px * 6 + 6) {
                for c in 0..<3 { image.planes[c][y * 120 + x] = sample[c] }
            } }
        } }
        return image
    }

    func testARollsTonalStepsPutItsRecordsOnTheFilmsOwnContrast() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let steepness = SIMD3<Float>(0.8, 1, 1.1)
        let measures = try (0..<6).map { seed in
            let preview = frame(stock, model, steepness: steepness, seed: seed)
            return ApproximateNegativeScan.RollBalance.Measure(
                denseEnd: try XCTUnwrap(ApproximateNegativeScan.denseEnd(border: model.clear,
                                                                         preview: preview)),
                slopes: try XCTUnwrap(ApproximateNegativeScan.tonalSlopes(border: model.clear,
                                                                          preview: preview)))
        }
        let roll = try XCTUnwrap(ApproximateNegativeScan.RollBalance(measures: measures))
        let slopes = try XCTUnwrap(roll.slopes)
        let gains = ApproximateNegativeScan.contrast(
            stock: stock, weights: model.weights(separation: 1), slopes: SIMD2(slopes[0], slopes[1]))
        XCTAssertEqual(gains.x, 1 / steepness.x, accuracy: 0.04)
        XCTAssertEqual(gains.y, 1)
        XCTAssertEqual(gains.z, 1 / steepness.z, accuracy: 0.04)

        // Balanced on a grey highlight, the greys under it read as the film's own with the
        // roll's contrast and drift off colour without it.
        func developed(_ exposure: Float) -> [Float] {
            let film = NegativeScanModel.density(stock: stock, logExposure: exposure)
            return (0..<3).map {
                stock.curves[$0].dMin + steepness[$0] * (film[$0] - stock.curves[$0].dMin)
            }
        }
        let highlight = try XCTUnwrap(model.scannerDensity(density: developed(0.6)))
        func worst(_ roll: ApproximateNegativeScan.RollBalance?) throws -> Float {
            let balance = ApproximateNegativeScan.balance(
                stock: stock, setup: setup, separation: 1, mode: .frame,
                tones: .init(denseEnd: highlight), roll: roll)
            let reading = try ApproximateNegativeScan(
                stock: stock, border: model.clear, gains: balance.gains, exposure: balance.exposure,
                weights: balance.weights)
            var worst: Float = 0
            for exposure in stride(from: Float(-1.2), through: 0.6, by: 0.3) {
                let read = try XCTUnwrap(reading.density(of: model.sample(density: developed(exposure))))
                let grey = NegativeScanModel.density(
                    stock: stock, logExposure: stock.curves[1].logExposure(density: read.y))
                for record in [0, 2] { worst = max(worst, abs(read[record] - grey[record])) }
            }
            return worst
        }
        XCTAssertLessThan(try worst(roll), 0.04)
        XCTAssertGreaterThan(try worst(nil), 0.1)
    }

    func testContrastStaysInsideWhatARollCanBe() throws {
        let stock = try stock("gold200")
        let straight = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        let range = ApproximateNegativeScan.contrastRange
        let steep = ApproximateNegativeScan.contrast(stock: stock, weights: straight,
                                                     slopes: SIMD2(0.1, 9))
        XCTAssertEqual(steep, SIMD3(range.upperBound, 1, range.lowerBound))
        XCTAssertNoThrow(try ApproximateNegativeScan(
            stock: stock, border: SIMD3(0.5, 0.25, 0.12), gains: steep, weights: straight))
        // A rise that reads no record, and a film with one record, keep the film's own.
        XCTAssertEqual(ApproximateNegativeScan.contrast(stock: stock, weights: straight,
                                                        slopes: SIMD2(.nan, 1)).x, 1)
        XCTAssertEqual(ApproximateNegativeScan.contrast(stock: stock, weights: straight,
                                                        slopes: SIMD2(-0.2, 1)).x, 1)
        XCTAssertEqual(ApproximateNegativeScan.contrast(
            stock: try self.stock("hp5plus400"), weights: straight, slopes: SIMD2(0.5, 2)), .one)
    }
}
