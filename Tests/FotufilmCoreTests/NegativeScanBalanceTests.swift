import XCTest
@testable import FotufilmCore

/// A frame read by the scan model is balanced on a neutral put on the film's own grey scale: by
/// an exposure added to red and blue where its roll measured how steep its records read, and by
/// scaling them where none did.
final class NegativeScanBalanceTests: XCTestCase {
    private func stock(_ id: String) throws -> FilmStock {
        try XCTUnwrap(FilmStock.presetDefinitions[id]).validated().stock
    }

    private let setup = NegativeScanSetup(light: .white, camera: .profile("sony-ilce-7cm2"))
    /// A scene lit warmer than the film expects: red exposed more, blue less.
    private let cast = SIMD3<Float>(0.15, 0, -0.2)

    private func reading(_ stock: FilmStock, _ model: NegativeScanModel,
                         _ balance: ApproximateNegativeScan.Balance) throws -> ApproximateNegativeScan {
        try ApproximateNegativeScan(stock: stock, border: model.clear, gains: balance.gains,
                                    exposure: balance.exposure, weights: balance.weights)
    }

    /// A roll that measured its tonal steps on film the model reads as it is: how red and blue
    /// rise per unit of green between two of its greys.
    private func measured(_ stock: FilmStock, _ model: NegativeScanModel,
                          neutral: SIMD3<Float>? = nil) throws -> ApproximateNegativeScan.RollBalance {
        // Between the greys the film's own rise is taken between (`greyRise`).
        let green = stock.curves[1]
        let top = min(1.2, 0.8 * (green.dMax - green.dMin))
        let low = try XCTUnwrap(model.scannerDensity(density: NegativeScanModel.density(
            stock: stock, logExposure: green.logExposure(density: green.dMin + 0.2))))
        let high = try XCTUnwrap(model.scannerDensity(density: NegativeScanModel.density(
            stock: stock, logExposure: green.logExposure(density: green.dMin + top))))
        let rise = high - low
        let colour = neutral.map { [$0.x / $0.y, $0.z / $0.y] } ?? [high.x / high.y, high.z / high.y]
        return .init(colour: colour, frames: 12, level: neutral?.y ?? high.y,
                     slopes: [rise.x / rise.y, rise.z / rise.y])
    }

    /// A camera nobody measured is read as the median sensor. Under a broad lamp, a white LED
    /// panel or a halogen lamp, its fit's density scale is close enough to the film's to keep, as
    /// a known setup's is. Under a screen, whose emitters differ between panels, the reading
    /// keeps the scan's own density of green as the film's, as an earlier reading did.
    func testAnUnmeasuredCameraKeepsTheFitsScaleUnderABroadLamp() throws {
        let stock = try stock("gold200")
        typealias Setup = NegativeScanSetup
        XCTAssertTrue(Setup(light: .white, camera: .profile("sony-ilce-7cm2")).knowsScale)
        XCTAssertTrue(Setup(light: .white, camera: .scanner).knowsScale)
        XCTAssertTrue(Setup(light: .rgb, camera: .generic).knowsScale)
        for light in [NegativeScanCrosstalk.Light.white, .screen, .halogen] {
            XCTAssertFalse(Setup(light: light, camera: .generic).knowsScale)
        }
        XCTAssertFalse(Setup(light: .white, camera: .profile("no-such-camera")).knowsScale)
        for light in [NegativeScanCrosstalk.Light.white, .halogen] {
            XCTAssertTrue(Setup(light: light, camera: .generic).keepsFittedScale)
            XCTAssertTrue(Setup(light: light, camera: .profile("no-such-camera")).keepsFittedScale)
        }
        XCTAssertFalse(Setup(light: .screen, camera: .generic).keepsFittedScale)
        XCTAssertFalse(Setup(light: .screen, camera: .profile("no-such-camera")).keepsFittedScale)
        XCTAssertTrue(Setup(light: .screen, camera: .scanner).keepsFittedScale)
        XCTAssertTrue(Setup(light: .screen, camera: .profile("sony-ilce-7cm2")).keepsFittedScale)

        func weights(_ setup: Setup, _ separation: Float) throws -> [SIMD3<Float>] {
            try XCTUnwrap(ApproximateNegativeScan.balance(
                stock: stock, setup: setup, separation: separation, mode: .none,
                tones: .init()).weights)
        }
        // A screen: the fit over what its green record reads of its own channel.
        let screen = Setup(light: .screen, camera: .generic)
        let model = NegativeScanModel(stock: stock, setup: screen)
        let fitted = model.weights(separation: 0), full = model.weights(separation: 1)
        XCTAssertGreaterThan(fitted[1].y, 1.02)
        for separation: Float in [0, 1] {
            let read = try weights(screen, separation)
            let expected = separation == 0 ? fitted : full
            for record in 0..<3 { for channel in 0..<3 {
                XCTAssertEqual(read[record][channel], expected[record][channel] / fitted[1].y,
                               accuracy: 1e-6)
            } }
        }
        // With the dyes unseparated, green reads the density its channel does.
        XCTAssertEqual(try weights(screen, 0)[1], SIMD3(0, 1, 0))
        // A broad lamp and a known setup take the fit as it is.
        for setup in [Setup(light: .white, camera: .generic), Setup(light: .halogen, camera: .generic),
                      Setup(light: .white, camera: .profile("sony-ilce-7cm2"))] {
            let model = NegativeScanModel(stock: stock, setup: setup)
            for separation: Float in [0, 1] {
                XCTAssertEqual(try weights(setup, separation), model.weights(separation: separation))
            }
        }
        // So a grey the film made reads the density that made it, where the scan's own green
        // reads it low.
        let white = Setup(light: .white, camera: .generic)
        let whiteModel = NegativeScanModel(stock: stock, setup: white)
        XCTAssertGreaterThan(whiteModel.weights(separation: 0)[1].y, 1.1)
        let grey = NegativeScanModel.density(stock: stock, logExposure: 0.3)
        let scan = try XCTUnwrap(whiteModel.scannerDensity(density: grey))
        for separation: Float in [0, 1] {
            let read = NegativeScanCrosstalk.apply(try weights(white, separation), scan)
            for record in 0..<3 {
                XCTAssertEqual(read[record], grey[record] - stock.curves[record].dMin,
                               accuracy: 0.04, "\(separation) \(record)")
            }
        }
    }

    /// Even on a single frame without a roll, the neutral balances by shifting exposure along
    /// each record's characteristic curve rather than warping its gamma, holding greys down the
    /// toe while keeping clear film at the stock's base. Its records keep the model's contrast:
    /// one frame's tonal steps follow its picture, and only a roll's say how steep they read.
    func testASingleFrameBalancesByExposureAndKeepsTheModelsContrast() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let highlight = NegativeScanModel.density(stock: stock, logExposure: 0.6, shift: cast)
        let neutral = try XCTUnwrap(model.scannerDensity(density: highlight))
        let balance = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: neutral))
        XCTAssertEqual(balance.gains, .one)
        XCTAssertEqual(balance.exposure.y, 0)
        XCTAssertEqual(balance.exposure.x, -cast.x, accuracy: 0.05)
        XCTAssertEqual(balance.exposure.z, -cast.z, accuracy: 0.05)
        let reading = try reading(stock, model, balance)
        let read = try XCTUnwrap(reading.density(of: model.sample(density: highlight)))
        let expected = grey(stock, green: read.y)
        for record in 0..<3 { XCTAssertEqual(read[record], expected[record], accuracy: 0.004) }
        let clear = try XCTUnwrap(reading.density(of: model.clear))
        for record in 0..<3 {
            XCTAssertEqual(clear[record], stock.curves[record].dMin, accuracy: 1e-5)
        }
        // Unlike scaling densities by a gain, the single-frame exposure balance holds down into
        // the toe without mid-tone/shadow colour crossover.
        for exposure in stride(from: Float(-1.8), through: 0.6, by: 0.3) {
            let film = NegativeScanModel.density(stock: stock, logExposure: exposure, shift: cast)
            let sampleRead = try XCTUnwrap(reading.density(of: model.sample(density: film)))
            let target = grey(stock, green: sampleRead.y)
            for record in [0, 2] {
                XCTAssertLessThan(abs(sampleRead[record] - target[record]), 0.04,
                                  "\(exposure) \(record)")
            }
        }
    }

    /// The film's grey of the exposure `green` density reads.
    private func grey(_ stock: FilmStock, green: Float) -> [Float] {
        NegativeScanModel.density(stock: stock,
                                  logExposure: stock.curves[1].logExposure(density: green))
    }

    func testAFramesNeutralLandsOnTheFilmsGreyScale() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let highlight = NegativeScanModel.density(stock: stock, logExposure: 0.6, shift: cast)
        let neutral = try XCTUnwrap(model.scannerDensity(density: highlight))
        let balance = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: neutral), roll: try measured(stock, model))
        for record in 0..<3 { XCTAssertEqual(balance.gains[record], 1, accuracy: 0.03) }
        // The exposure the scene's light added, taken back off, less what the roll's contrast
        // already moved the neutral by.
        XCTAssertEqual(balance.exposure.y, 0)
        XCTAssertEqual(balance.exposure.x, -cast.x, accuracy: 0.07)
        XCTAssertEqual(balance.exposure.z, -cast.z, accuracy: 0.07)
        XCTAssertEqual(balance.weights, model.weights(separation: 1))
        let reading = try reading(stock, model, balance)

        // The neutral itself reads as the film's grey.
        let read = try XCTUnwrap(reading.density(of: model.sample(density: highlight)))
        let expected = grey(stock, green: read.y)
        for record in 0..<3 { XCTAssertEqual(read[record], expected[record], accuracy: 0.004) }
        // The highlights' exposure is the one the densest end's green reads.
        let stops = try XCTUnwrap(balance.highlightStops)
        XCTAssertEqual(stops, stock.curves[1].logExposure(density: read.y) / log10(2),
                       accuracy: 0.01)
    }

    /// A neutral that reads red a little dense is moved by that density on the straight line,
    /// wherever on the curve the neutral lies. On the shoulder the curve's own inverse asks for
    /// an exposure several times as long, which would tint every tone below the neutral.
    func testANeutralOnTheShoulderMovesTheStraightLineByNoMoreThanItIsOff() throws {
        let stock = try stock("gold200")
        let identity: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let slopes = try XCTUnwrap(ApproximateNegativeScan.greySlopes(stock))
        let off: Float = 0.13
        func exposure(at logExposure: Float) -> (limited: Float, inverse: Float) {
            let film = NegativeScanModel.density(stock: stock, logExposure: logExposure)
            var neutral = SIMD3((0..<3).map { film[$0] - stock.curves[$0].dMin })
            neutral.x += off
            let limited = ApproximateNegativeScan.exposure(
                stock: stock, weights: identity, gains: .one, neutral: neutral)
            let red = stock.curves[0]
            return (limited.x, logExposure - red.logExposure(density: red.dMin + neutral.x))
        }
        // On the straight line the limit is the curve's own inverse.
        let line = exposure(at: 0.5)
        XCTAssertEqual(line.limited, line.inverse, accuracy: 0.02)
        XCTAssertEqual(line.limited, -off / slopes.x, accuracy: 0.03)
        // Past the knee the inverse is much longer; the balance stays what the line needs.
        let shoulder = exposure(at: 1.6)
        XCTAssertLessThan(shoulder.inverse, 1.4 * line.inverse)
        XCTAssertEqual(shoulder.limited, -off / slopes.x, accuracy: 0.03)
    }

    /// The cast is one exposure at every tone, so the balance holds from the deepest shadow
    /// to the highlights, and the clear film, which no exposure made, stays the film's base. One
    /// density added at every tone, as a balance in density is, tints the shadows by most of it.
    func testTheBalanceHoldsDownTheToeAndLeavesTheClearFilm() throws {
        for id in ["gold200", "portra400"] {
            let stock = try stock(id)
            let model = NegativeScanModel(stock: stock, setup: setup)
            let highlight = NegativeScanModel.density(stock: stock, logExposure: 0.6, shift: cast)
            let neutral = try XCTUnwrap(model.scannerDensity(density: highlight))
            let balance = ApproximateNegativeScan.balance(
                stock: stock, setup: setup, separation: 1, mode: .frame,
                tones: .init(denseEnd: neutral), roll: try measured(stock, model))
            let reading = try reading(stock, model, balance)
            let unbalanced = try ApproximateNegativeScan(stock: stock, border: model.clear,
                                                         gains: balance.gains,
                                                         weights: balance.weights)
            var shadowCast: Float = 0
            for exposure in stride(from: Float(-2.4), through: 0.9, by: 0.15) {
                let film = NegativeScanModel.density(stock: stock, logExposure: exposure,
                                                     shift: cast)
                let read = try XCTUnwrap(reading.density(of: model.sample(density: film)))
                let expected = grey(stock, green: read.y)
                // What the fit itself misses a grey lit as the film expects by, at this tone.
                let even = try XCTUnwrap(unbalanced.density(of: model.sample(
                    density: NegativeScanModel.density(stock: stock, logExposure: exposure))))
                let evenExpected = grey(stock, green: even.y)
                for record in [0, 2] {
                    XCTAssertLessThan(abs(read[record] - expected[record]),
                                      abs(even[record] - evenExpected[record]) + 0.035,
                                      "\(id) \(exposure) \(record)")
                }
                if exposure < -1.8 {
                    let plain = try XCTUnwrap(unbalanced.density(of: model.sample(density: film)))
                    shadowCast = max(shadowCast, abs(read.x - plain.x))
                }
            }
            // In the deepest shadows the balance has little left to move.
            XCTAssertLessThan(shadowCast, 0.03, id)
            let clear = try XCTUnwrap(reading.density(of: model.clear))
            for record in 0..<3 {
                XCTAssertEqual(clear[record], stock.curves[record].dMin, accuracy: 1e-5, id)
            }
            // On the straight line the same balance is most of a tenth of a density.
            let line = try XCTUnwrap(model.scannerDensity(
                density: NegativeScanModel.density(stock: stock, logExposure: 0.3, shift: cast)))
            let read = NegativeScanCrosstalk.apply(balance.weights ?? [], line)
            XCTAssertGreaterThan(abs(reading.balance(record: 0, read: read.x)), 0.04, id)
        }
    }

    func testNoBalanceReadsTheFilmAsItIsAndStillTimesThePrint() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let highlight = NegativeScanModel.density(stock: stock, logExposure: 0.6, shift: cast)
        let neutral = try XCTUnwrap(model.scannerDensity(density: highlight))
        let tones = ApproximateNegativeScan.Tones(denseEnd: neutral)
        let none = ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: 1,
                                                   mode: .none, tones: tones)
        XCTAssertEqual(none.exposure, .zero)
        XCTAssertEqual(none.gains, .one)
        XCTAssertEqual(none.highlightStops, ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame, tones: tones).highlightStops)
        let read = try XCTUnwrap(try reading(stock, model, none)
            .density(of: model.sample(density: highlight)))
        for record in 0..<3 { XCTAssertEqual(read[record], highlight[record], accuracy: 0.03) }
    }

    /// A frame of `densities` over `border`, each filling the rectangle given in tenths of the
    /// frame, the first the whole of it.
    private func frame(border: SIMD3<Float>,
                       _ patches: [(density: SIMD3<Float>, x: Range<Int>, y: Range<Int>)]) -> ImageBuffer {
        var image = ImageBuffer(width: 100, height: 100)
        for patch in patches {
            for y in patch.y { for x in patch.x {
                for c in 0..<3 {
                    image.planes[c][y * 100 + x] = border[c] * pow(10, -patch.density[c])
                }
            } }
        }
        return image
    }

    func testTheDensestEndIsOneSetOfPixelsWhichASaturatedColourCannotStandInFor() throws {
        let border = SIMD3<Float>(0.8, 0.5, 0.25)
        // A grey wall, a small white, and a yellow flower in the sun: as dense as nothing else
        // to red and green, and thin to blue.
        let wall = SIMD3<Float>(0.6, 0.6, 0.6), white = SIMD3<Float>(1, 1.05, 1.1)
        let flower = SIMD3<Float>(1.6, 1.3, 0.3)
        let image = frame(border: border, [
            (wall, 0..<100, 0..<100), (flower, 20..<40, 40..<60), (white, 60..<70, 40..<60),
        ])
        let dense = try XCTUnwrap(ApproximateNegativeScan.denseEnd(border: border, preview: image))
        for c in 0..<3 { XCTAssertEqual(dense[c], white[c], accuracy: 1e-5) }
        // Each channel's own densest pixels are the flower's red and green and the white's
        // blue, no object of the frame; the first reading keeps them.
        let ends = try XCTUnwrap(ApproximateNegativeScan.channelEnds(border: border, preview: image))
        for (c, value) in [flower.x, flower.y, white.z].enumerated() {
            XCTAssertEqual(ends[c], value, accuracy: 1e-5)
        }
        // A frame whose densest pixels are a grey reads the same either way.
        let grey = frame(border: border, (0..<100).map { x in
            (SIMD3(repeating: Float(x) / 100), x..<(x + 1), 0..<100)
        })
        let one = try XCTUnwrap(ApproximateNegativeScan.denseEnd(border: border, preview: grey))
        let each = try XCTUnwrap(ApproximateNegativeScan.channelEnds(border: border, preview: grey))
        for c in 0..<3 { XCTAssertEqual(one[c], each[c], accuracy: 1e-5) }
        XCTAssertNil(ApproximateNegativeScan.denseEnd(border: border,
                                                      preview: ImageBuffer(width: 1, height: 1)))
    }

    func testTheMidTonesAreTheFramesMeanDensity() throws {
        let border = SIMD3<Float>(0.8, 0.5, 0.25)
        let image = frame(border: border, [
            (SIMD3(0.2, 0.4, 0.6), 0..<100, 0..<100), (SIMD3(0.6, 1.2, 1.8), 50..<100, 0..<100),
        ])
        let midtone = try XCTUnwrap(ApproximateNegativeScan.midtone(border: border, preview: image))
        for (c, value) in [Float(0.4), 0.8, 1.2].enumerated() {
            XCTAssertEqual(midtone[c], value, accuracy: 1e-4)
        }
        XCTAssertNil(ApproximateNegativeScan.midtone(border: border,
                                                     preview: ImageBuffer(width: 1, height: 1)))
    }

    /// A frame's average is what its tones come to between the toe and its densest highlights:
    /// a lamp, the clear film around a subject and a few pixels of a colour do not move it.
    func testTheAverageIsTheMiddleOfTheFramesTones() throws {
        let border = SIMD3<Float>(0.8, 0.5, 0.25)
        let wall = SIMD3<Float>(0.52, 0.6, 0.71), lamp = SIMD3<Float>(2.4, 2.2, 1.9)
        let image = frame(border: border, [
            (wall, 0..<100, 0..<100), (SIMD3(0.03, 0.04, 0.02), 0..<100, 10..<30),
            (lamp, 40..<60, 40..<50), (SIMD3(1.3, 0.9, 0.2), 60..<64, 60..<64),
        ])
        let average = try XCTUnwrap(ApproximateNegativeScan.average(border: border, preview: image))
        for c in 0..<3 { XCTAssertEqual(average[c], wall[c], accuracy: 1e-5) }
        // A night with a few lamps has too little between its shadows and its lamps to tell.
        let night = frame(border: border, [
            (SIMD3(0.03, 0.04, 0.02), 0..<100, 0..<100), (lamp, 40..<60, 40..<50),
            (wall, 50..<55, 60..<65),
        ])
        XCTAssertNil(ApproximateNegativeScan.average(border: border, preview: night))
        XCTAssertNil(ApproximateNegativeScan.average(border: border,
                                                     preview: ImageBuffer(width: 1, height: 1)))
    }

    /// The clearest film of an area drawn for it is its clearest tenth: the rebate where the
    /// area takes in picture and a little dust with it, and not the few brightest pixels.
    func testTheClearestFilmOfADrawnAreaIsItsClearestTenth() throws {
        let border = SIMD3<Float>(0.8, 0.5, 0.25)
        // A fifth of the area is rebate, the rest picture; one pixel in two hundred of the
        // rebate is a pinhole that passes a little more.
        var image = frame(border: border, [
            (SIMD3(0.6, 0.7, 0.8), 0..<100, 0..<100), (SIMD3(0.02, 0.02, 0.02), 0..<100, 0..<20),
        ])
        for i in stride(from: 0, to: 2000, by: 200) {
            for c in 0..<3 { image.planes[c][i] = border[c] * 1.3 }
        }
        let clear = try XCTUnwrap(ApproximateNegativeScan.clearestFilm(preview: image))
        for c in 0..<3 { XCTAssertEqual(clear[c], border[c] * pow(10, -0.02), accuracy: 1e-5) }
        // A whole scan's estimate, its clearest hundredth, reads the same film here.
        let estimated = try XCTUnwrap(ApproximateNegativeScan.estimatedBorder(preview: image))
        XCTAssertEqual(estimated.y, border.y * pow(10, -0.02), accuracy: 1e-5)
        XCTAssertNil(ApproximateNegativeScan.clearestFilm(preview: ImageBuffer(width: 4, height: 4)))
    }

    /// A picture area picked on the scan is measured whole: set in a frame a quarter larger,
    /// the central 80% the measures read is all of it, where a frame nobody picked loses a
    /// tenth at every edge.
    func testAPickedPictureAreaIsMeasuredWhole() throws {
        let border = SIMD3<Float>(0.8, 0.5, 0.25)
        // A highlight along the area's top edge, which the central 80% of the area leaves out.
        let image = frame(border: border, [
            (SIMD3(0.4, 0.5, 0.6), 0..<100, 0..<100), (SIMD3(1.6, 1.7, 1.8), 0..<100, 0..<8),
        ])
        let inset = try XCTUnwrap(ApproximateNegativeScan.denseEnd(border: border, preview: image))
        XCTAssertEqual(inset.y, 0.5, accuracy: 1e-5)
        let whole = ApproximateNegativeScan.pictureArea(image)
        XCTAssertEqual(whole.width - 2 * (whole.width / 10), image.width)
        XCTAssertEqual(whole.height - 2 * (whole.height / 10), image.height)
        let picked = try XCTUnwrap(ApproximateNegativeScan.denseEnd(border: border, preview: whole))
        XCTAssertEqual(picked.y, 1.7, accuracy: 1e-5)
        // Its mid-tones are the mean of every pixel of the area, and of none around it.
        let middle = try XCTUnwrap(ApproximateNegativeScan.midtone(border: border, preview: whole))
        XCTAssertEqual(middle.y, 0.92 * 0.5 + 0.08 * 1.7, accuracy: 1e-4)
        XCTAssertNotNil(ApproximateNegativeScan.average(border: border, preview: whole))
        // Sizes the tenths do not divide still hold the area and at most a pixel more.
        for size in [1, 7, 16, 33, 341, 512] {
            let odd = ApproximateNegativeScan.pictureArea(ImageBuffer(width: size, height: 3, fill: 0.2))
            XCTAssertGreaterThanOrEqual(odd.width - 2 * (odd.width / 10), size)
            XCTAssertLessThanOrEqual(odd.width - 2 * (odd.width / 10), size + 1)
            XCTAssertEqual(odd.planes[1].filter(\.isFinite).count, size * 3)
        }
    }

    /// A frame is balanced on its average before its densest end: the sun on a white wall at
    /// dusk is the frame's brightest thing and far from white.
    func testAFrameIsBalancedOnItsAverageBeforeItsDensestEnd() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let middle = try XCTUnwrap(model.scannerDensity(
            density: NegativeScanModel.density(stock: stock, logExposure: -0.2, shift: cast)))
        let sunlit = try XCTUnwrap(model.scannerDensity(density: NegativeScanModel.density(
            stock: stock, logExposure: 0.7, shift: cast + SIMD3(0.3, 0, -0.4))))
        let balance = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: sunlit, average: middle))
        XCTAssertEqual(balance.gains, .one)
        XCTAssertEqual(balance.exposure.x, -cast.x, accuracy: 0.05)
        XCTAssertEqual(balance.exposure.z, -cast.z, accuracy: 0.05)
        // The densest end still times the print, and stands in where a frame has no average.
        let ends = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame, tones: .init(denseEnd: sunlit))
        XCTAssertEqual(balance.highlightStops, ends.highlightStops)
        XCTAssertEqual(ends.exposure.x, -(cast.x + 0.3), accuracy: 0.08)
        // A neutral picked on the frame comes before either.
        let picked = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: sunlit, picked: sunlit, average: middle))
        XCTAssertEqual(picked.exposure, ends.exposure)
    }

    /// Every frame of a roll is balanced on the average the roll's frames come to, whatever
    /// its own picture shows.
    func testFramesOnTheirRollAreBalancedOnTheRollsAverage() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let middle = try XCTUnwrap(model.scannerDensity(
            density: NegativeScanModel.density(stock: stock, logExposure: -0.2, shift: cast)))
        var roll = try measured(stock, model)
        roll.average = [middle.x, middle.y, middle.z]
        let own = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(average: middle), roll: roll)
        for frame in [SIMD3<Float>(1.9, 1.2, 0.5), SIMD3(0.4, 0.9, 1.6)] {
            let rolled = ApproximateNegativeScan.balance(
                stock: stock, setup: setup, separation: 1, mode: .roll,
                tones: .init(denseEnd: frame * 1.5, average: frame), roll: roll)
            XCTAssertEqual(rolled.exposure, own.exposure)
            XCTAssertEqual(rolled.gains, own.gains)
        }
    }

    func testASmallHighlightFarOverTheMidTonesDoesNotTimeThePrint() throws {
        let white = ApproximateNegativeScan.diffuseWhiteStops
        let span = ApproximateNegativeScan.highlightSpan
        let timed = ApproximateNegativeScan.timedHighlight
        // Highlights within the span of the mid-tones, or under a diffuse white, time the print.
        XCTAssertEqual(timed(5.5, 5.5 - span), 5.5)
        XCTAssertEqual(timed(4, 2), 4)
        XCTAssertEqual(timed(white, -6), white)
        XCTAssertEqual(timed(1, -6), 1)
        XCTAssertEqual(timed(5.5, .nan), 5.5)
        // Further over them, the print is timed the span over the mid-tones,
        XCTAssertEqual(timed(5.5, 1), 1 + span)
        // and no lighter than the film was exposed: a diffuse white prints as white.
        XCTAssertEqual(timed(5.5, -2), white)
        XCTAssertEqual(timed(7.5, -8), white)

        // A lamp in a dark room: a densest end five stops over the film's mid-grey, the frame's
        // mean three stops under it.
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let scanned = { (stops: Float) throws -> SIMD3<Float> in
            try XCTUnwrap(model.scannerDensity(density: NegativeScanModel.density(
                stock: stock, logExposure: stops * log10(2))))
        }
        let lamp = try scanned(5), room = try scanned(-3), day = try scanned(2.5)
        let balance = { (tones: ApproximateNegativeScan.Tones, mode: ApproximateNegativeScan.BalanceMode) in
            ApproximateNegativeScan.balance(stock: stock, setup: self.setup, separation: 1,
                                            mode: mode, tones: tones)
        }
        let alone = balance(.init(denseEnd: lamp), .frame)
        let dark = balance(.init(denseEnd: lamp, midtone: room), .frame)
        let bright = balance(.init(denseEnd: lamp, midtone: day), .frame)
        let highlight = try XCTUnwrap(alone.highlightStops)
        XCTAssertEqual(highlight, 5, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(dark.highlightStops), white, accuracy: 1e-4)
        XCTAssertEqual(bright.highlightStops, highlight)
        // The mid-tones time the print and nothing else: the balance is the neutral's.
        XCTAssertEqual(dark.exposure, alone.exposure)
        XCTAssertEqual(dark.gains, alone.gains)
        XCTAssertEqual(balance(.init(denseEnd: lamp, midtone: room), .none).highlightStops,
                       dark.highlightStops)
        XCTAssertEqual(balance(.init(denseEnd: lamp, midtone: SIMD3(.nan, 0.3, 0.3)), .frame)
            .highlightStops, highlight)
    }

    func testAPickedNeutralTakesTheDensestEndsPlace() throws {
        let stock = try stock("portra400")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let found = try XCTUnwrap(model.scannerDensity(
            density: NegativeScanModel.density(stock: stock, logExposure: 0.6)))
        let midtone = NegativeScanModel.density(stock: stock, logExposure: -0.2, shift: cast)
        let picked = try XCTUnwrap(model.scannerDensity(density: midtone))
        let balance = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: found, picked: picked))
        let read = try XCTUnwrap(try reading(stock, model, balance)
            .density(of: model.sample(density: midtone)))
        let expected = grey(stock, green: read.y)
        for record in 0..<3 { XCTAssertEqual(read[record], expected[record], accuracy: 0.002) }
        // The print is still timed on the highlights.
        XCTAssertEqual(balance.highlightStops, ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: found)).highlightStops)
    }

    func testAFrameTooFlatOrUnreadableIsLeftAsTheFilmReads() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let dense = try XCTUnwrap(model.scannerDensity(
            density: NegativeScanModel.density(stock: stock, logExposure: 0.6, shift: cast)))
        let roll = try measured(stock, model)
        func balance(_ tones: ApproximateNegativeScan.Tones) -> ApproximateNegativeScan.Balance {
            ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: 1,
                                            mode: .frame, tones: tones, roll: roll)
        }
        XCTAssertNotEqual(balance(.init(denseEnd: dense)).exposure, .zero)
        let flat = SIMD3<Float>(0.03, 0.02, 0.04)
        XCTAssertEqual(balance(.init(denseEnd: flat)).exposure, .zero)
        XCTAssertNil(balance(.init(denseEnd: flat)).highlightStops)
        XCTAssertEqual(balance(.init()).exposure, .zero)
        XCTAssertEqual(balance(.init(denseEnd: SIMD3(.nan, 1, 1))).exposure, .zero)
        // Without a roll's contrast a single frame likewise leaves unreadable frames alone and
        // clamps wild exposures to the range a reading takes.
        func single(_ tones: ApproximateNegativeScan.Tones) -> ApproximateNegativeScan.Balance {
            ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: 1,
                                            mode: .frame, tones: tones)
        }
        XCTAssertEqual(single(.init(denseEnd: flat)).exposure, .zero)
        XCTAssertEqual(single(.init()).exposure, .zero)
        XCTAssertEqual(single(.init(denseEnd: SIMD3(0.1, 0.8, 3.6))).exposure.z,
                       ApproximateNegativeScan.exposureRange.lowerBound)
        // An exposure stops at the range a reading takes, and a record the neutral reads no
        // density of has no exposure to be placed at.
        let wild = balance(.init(denseEnd: SIMD3(0.1, 1.2, 3)))
        XCTAssertNoThrow(try reading(stock, model, wild))
        XCTAssertEqual(wild.exposure.z, ApproximateNegativeScan.exposureRange.lowerBound)
        XCTAssertEqual(wild.exposure.x, 0)
    }

    func testABlackAndWhiteFilmHasNothingToBalance() throws {
        let stock = try stock("hp5plus400")
        let dense = SIMD3<Float>(0.9, 1.1, 1.3)
        let balance = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: dense))
        XCTAssertEqual(balance.exposure, .zero)
        XCTAssertEqual(balance.gains, .one)
        XCTAssertNotNil(balance.highlightStops)
    }

    func testFramesOnTheirRollShareOneBalance() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        func dense(_ exposure: Float, _ shift: SIMD3<Float>) throws -> SIMD3<Float> {
            try XCTUnwrap(model.scannerDensity(
                density: NegativeScanModel.density(stock: stock, logExposure: exposure, shift: shift)))
        }
        // The roll's neutral carries the cast; one frame's own densest end is a blue sky.
        let neutral = try dense(0.6, cast)
        let roll = try measured(stock, model, neutral: neutral)
        // The same contrast with no neutral of its roll's to take: a frame on its own.
        var alone = roll
        alone.level = nil
        let sky = try dense(0.4, SIMD3(-0.2, 0, 0.3))
        func balance(_ mode: ApproximateNegativeScan.BalanceMode, _ end: SIMD3<Float>,
                     roll: ApproximateNegativeScan.RollBalance?,
                     picked: SIMD3<Float>? = nil) -> ApproximateNegativeScan.Balance {
            ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: 1, mode: mode,
                                            tones: .init(denseEnd: end, picked: picked), roll: roll)
        }
        let rolled = balance(.roll, sky, roll: roll)
        XCTAssertNotEqual(rolled.exposure, .zero)
        let own = balance(.frame, neutral, roll: roll).exposure
        for record in 0..<3 { XCTAssertEqual(rolled.exposure[record], own[record], accuracy: 1e-4) }
        XCTAssertEqual(rolled.exposure, balance(.roll, neutral, roll: roll).exposure)
        // Each frame's print is still timed on its own highlights.
        XCTAssertEqual(rolled.highlightStops, balance(.frame, sky, roll: nil).highlightStops)
        XCTAssertNotEqual(rolled.highlightStops, balance(.roll, neutral, roll: roll).highlightStops)
        // A neutral picked on the frame is the frame's, not the roll's.
        XCTAssertEqual(balance(.roll, sky, roll: roll, picked: sky).exposure, rolled.exposure)
        // The frame's own balance leaves the roll's neutral alone, and no balance leaves both.
        XCTAssertNotEqual(balance(.frame, sky, roll: roll).exposure, rolled.exposure)
        XCTAssertEqual(balance(.none, sky, roll: roll).exposure, .zero)
        // Without a roll the frame is balanced on its own.
        XCTAssertEqual(balance(.roll, sky, roll: nil), balance(.frame, sky, roll: nil))
        XCTAssertEqual(balance(.roll, sky, roll: roll, picked: neutral).exposure,
                       balance(.roll, sky, roll: roll).exposure)
        XCTAssertEqual(balance(.frame, sky, roll: roll, picked: neutral).exposure, own)
        _ = alone
    }

    func testARollKeptWithoutItsLevelBalancesAtTheFramesOwn() throws {
        let stock = try stock("gold200")
        let old = ApproximateNegativeScan.RollBalance(colour: [0.62, 1.2], frames: 5)
        let end = SIMD3<Float>(0.5, 1.1, 1.6)
        let rolled = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .roll, tones: .init(denseEnd: end),
            roll: old)
        let own = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: SIMD3(0.62 * 1.1, 1.1, 1.2 * 1.1)))
        // A roll kept without its tonal steps balances by exposure at the frame's green level,
        // just as a frame's own neutral does.
        XCTAssertEqual(rolled.gains, .one)
        XCTAssertEqual(rolled.exposure, own.exposure)
        XCTAssertNotEqual(rolled.exposure, .zero)
        // A frame that cannot be read has no level to take the roll's colour at.
        XCTAssertEqual(ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .roll, tones: .init(), roll: old).exposure,
            .zero)
    }

    func testARollsContrastHoldsWhicheverNeutralBalancesTheFrame() throws {
        let stock = try stock("gold200")
        let weights = NegativeScanModel(stock: stock, setup: setup).weights(separation: 1)
        let roll = ApproximateNegativeScan.RollBalance(colour: [0.62, 1.2], frames: 8, level: 1.2,
                                                      slopes: [0.5, 1.3])
        let gains = ApproximateNegativeScan.contrast(stock: stock, weights: weights,
                                                     slopes: SIMD2(0.5, 1.3))
        XCTAssertNotEqual(gains.x, 1, accuracy: 0.02)
        let tones = ApproximateNegativeScan.Tones(denseEnd: SIMD3(0.7, 1.1, 1.4))
        for mode in [ApproximateNegativeScan.BalanceMode.frame, .roll] {
            XCTAssertEqual(ApproximateNegativeScan.balance(
                stock: stock, setup: setup, separation: 1, mode: mode, tones: tones,
                roll: roll).gains, gains)
        }
        XCTAssertEqual(ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .none, tones: tones, roll: roll).gains,
            .one)
    }
}
