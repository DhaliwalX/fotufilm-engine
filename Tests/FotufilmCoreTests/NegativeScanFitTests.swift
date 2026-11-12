import XCTest
@testable import FotufilmCore

final class NegativeScanFitTests: XCTestCase {
    private typealias Setup = NegativeScanSetup

    /// Every colour negative a scan can be read as.
    private var negatives: [FilmStock] {
        FilmStock.presetIDs.compactMap { FilmStock.presets[$0] }
            .filter { !$0.isReversal && !$0.isReflectionPrint && !$0.isMonochrome }
    }

    private let setups: [Setup] = [
        Setup(light: .white, camera: .generic),
        Setup(light: .white, camera: .profile("sony-ilce-7cm2")),
        Setup(light: .halogen, camera: .profile("sony-ilce-7cm2")),
        Setup(light: .screen, camera: .profile("sony-ilce-7cm2")),
        Setup(light: .white, camera: .scanner),
        Setup(light: .rgb, camera: .generic),
    ]

    private func error(_ model: NegativeScanModel, weights: [SIMD3<Float>]?,
                       gains: SIMD3<Float> = .one) throws -> NegativeScanModel.ReadingError {
        let reading = try ApproximateNegativeScan(stock: model.stock, border: model.clear,
                                                  gains: gains, weights: weights)
        return model.error(of: reading, patches: NegativeScanModel.patches(stock: model.stock))
    }

    /// The fitted reading returns the film that made the scan: its greys within a hundredth or
    /// two of a density and its colours within a few, under every lamp and camera, where each
    /// record read from its own channel at unit weight misses by several times as much.
    func testTheFittedReadingReturnsTheFilm() throws {
        XCTAssertGreaterThanOrEqual(negatives.count, 5)
        for stock in negatives {
            for setup in setups {
                let model = NegativeScanModel(stock: stock, setup: setup)
                let plain = try error(model, weights: nil)
                let fitted = try error(model, weights: model.weights(separation: 1))
                let name = "\(stock.name) \(setup)"
                XCTAssertEqual(fitted.unread, 0, name)
                XCTAssertLessThan(fitted.greys, 0.025, name)
                XCTAssertLessThan(fitted.colours, 0.035, name)
                // A film modelled without its mask already reads its greys as they are.
                XCTAssertLessThan(fitted.greys, max(plain.greys / 3, 0.005), name)
                XCTAssertLessThan(fitted.colours, plain.colours / 3, name)
            }
        }
    }

    /// The frame's balance on today's reading scales red and blue to the film at one grey, which
    /// leaves green's contrast and every other tone where the scan put them. The fit holds them.
    func testTheFitHoldsTheGreysABalancedReadingLeavesOff() throws {
        for id in ["gold200", "portra400"] {
            let stock = try XCTUnwrap(FilmStock.presets[id])
            let model = NegativeScanModel(stock: stock, setup: setups[1])
            let dense = model.scannerDensity(
                density: NegativeScanModel.density(stock: stock, logExposure: 0.9))
            let balance = ApproximateNegativeScan.balance(
                stock: stock, denseEnd: dense, correction: .init(strength: 1, light: .white))
            let balanced = try error(model, weights: balance.weights, gains: balance.gains)
            let fitted = try error(model, weights: model.weights(separation: 1))
            XCTAssertGreaterThan(balanced.greys, 0.05, id)
            XCTAssertLessThan(fitted.greys, balanced.greys / 5, id)
            XCTAssertLessThan(fitted.colours, balanced.colours / 3, id)
        }
    }

    /// Separation runs from one channel per record, which already holds the greys, to the full
    /// fit, which brings the colours in.
    func testSeparationRunsFromEachRecordsOwnChannelToTheFullFit() throws {
        let stock = try XCTUnwrap(FilmStock.presets["gold200"])
        let model = NegativeScanModel(stock: stock, setup: setups[1])
        let own = model.weights(separation: 0), full = model.weights(separation: 1)
        let half = model.weights(separation: 0.5)
        for record in 0..<3 {
            for channel in 0..<3 {
                if record != channel { XCTAssertEqual(own[record][channel], 0) }
                XCTAssertEqual(half[record][channel],
                               (own[record][channel] + full[record][channel]) / 2, accuracy: 1e-5)
            }
        }
        // Light the cyan and magenta dyes pass fills a broad red or green channel, which reads
        // less density than the record has, so its own weight is over one.
        XCTAssertGreaterThan(own[0][0], 1.2)
        XCTAssertGreaterThan(own[1][1], 1.1)
        // Out of range clamps, and what is not a number reads as none.
        XCTAssertEqual(model.weights(separation: 3), full)
        XCTAssertEqual(model.weights(separation: -1), own)
        XCTAssertEqual(model.weights(separation: .nan), own)
        var last = Float.greatestFiniteMagnitude
        for separation in [Float(0), 0.25, 0.5, 0.75, 1] {
            let error = try error(model, weights: model.weights(separation: separation))
            XCTAssertLessThan(error.greys, 0.02)
            XCTAssertLessThan(error.colours, last)
            last = error.colours
        }
    }

    /// Narrow bands at the dyes read nearly the records themselves: little to take out of the
    /// other channels, and weights near one.
    func testNarrowBandsNeedLittleSeparation() throws {
        let stock = try XCTUnwrap(FilmStock.presets["gold200"])
        for setup in [setups[4], setups[5]] {
            let weights = NegativeScanModel(stock: stock, setup: setup).weights(separation: 1)
            for record in 0..<3 {
                for channel in 0..<3 where channel != record {
                    XCTAssertLessThan(abs(weights[record][channel]), 0.05, "\(setup)")
                }
                XCTAssertTrue((0.85...1.4).contains(weights[record][record]), "\(setup)")
            }
        }
        let broad = NegativeScanModel(stock: stock, setup: setups[0]).weights(separation: 1)
        XCTAssertLessThan(broad[0][1], -0.5, "a camera's red channel sees the magenta dye")
    }

    /// A camera's channel can read no light of a deep colour its matrix takes below zero. Those
    /// patches are left out and the rest still fit.
    func testPatchesAChannelCannotReadAreLeftOut() throws {
        let stock = try XCTUnwrap(FilmStock.presets["gold200"])
        // Blue less a share of green: negative under film that passes green and little blue.
        var response = Setup(light: .white, camera: .generic).response()
        response[2] = (0..<SpectralGrid.count).map { response[2][$0] - 0.12 * response[1][$0] }
        let model = NegativeScanModel(stock: stock, response: response)
        let patches = NegativeScanModel.patches(stock: stock)
        let read = patches.filter { model.scannerDensity(density: $0.density) != nil }
        XCTAssertLessThan(read.count, patches.count)
        XCTAssertGreaterThan(read.count, patches.count / 2)
        let weights = model.weights(separation: 1, patches: patches)
        XCTAssertEqual(weights, model.weights(separation: 1, patches: read))
        XCTAssertTrue(weights.allSatisfy { row in (0..<3).allSatisfy { row[$0].isFinite } })
    }

    /// Nothing to fit on reads each record from its own channel as it is, and a black-and-white
    /// film reads green alone.
    func testNoPatchesReadsEachChannelAsItIsAndMonochromeReadsGreen() throws {
        let stock = try XCTUnwrap(FilmStock.presets["gold200"])
        let model = NegativeScanModel(stock: stock, setup: setups[0])
        XCTAssertEqual(model.weights(separation: 1, patches: []),
                       [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])
        let silver = try XCTUnwrap(FilmStock.presets["trix400"])
        XCTAssertEqual(NegativeScanModel(stock: silver, setup: setups[0]).weights(separation: 1),
                       NegativeScanCrosstalk.weights(for: silver, correction: .none, neutral: nil))
    }
}
