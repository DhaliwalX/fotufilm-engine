import XCTest
@testable import FotufilmCore

/// A frame read by the scan model is balanced by an offset in density that puts its neutral on
/// the film's own grey scale.
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
                                    offset: balance.offset, weights: balance.weights)
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
            tones: .init(denseEnd: neutral))
        XCTAssertEqual(balance.gains, .one)
        XCTAssertEqual(balance.offset.y, 0)
        XCTAssertLessThan(balance.offset.x, -0.05)
        XCTAssertGreaterThan(balance.offset.z, 0.05)
        XCTAssertEqual(balance.weights, model.weights(separation: 1))
        let reading = try reading(stock, model, balance)

        // The neutral itself reads as the film's grey, and a stop under it stays close: the
        // cast is the same density down the film's straight line.
        let read = try XCTUnwrap(reading.density(of: model.sample(density: highlight)))
        let expected = grey(stock, green: read.y)
        let lower = NegativeScanModel.density(stock: stock, logExposure: 0.3, shift: cast)
        let lowerRead = try XCTUnwrap(reading.density(of: model.sample(density: lower)))
        let lowerExpected = grey(stock, green: lowerRead.y)
        for record in 0..<3 {
            XCTAssertEqual(read[record], expected[record], accuracy: 0.002)
            XCTAssertEqual(lowerRead[record], lowerExpected[record], accuracy: 0.03)
        }
        // The highlights' exposure is the one the densest end's green reads.
        let stops = try XCTUnwrap(balance.highlightStops)
        XCTAssertEqual(stops, stock.curves[1].logExposure(density: read.y) / log10(2),
                       accuracy: 0.01)
    }

    func testNoBalanceReadsTheFilmAsItIsAndStillTimesThePrint() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let highlight = NegativeScanModel.density(stock: stock, logExposure: 0.6, shift: cast)
        let neutral = try XCTUnwrap(model.scannerDensity(density: highlight))
        let tones = ApproximateNegativeScan.Tones(denseEnd: neutral)
        let none = ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: 1,
                                                   mode: .none, tones: tones)
        XCTAssertEqual(none.offset, .zero)
        XCTAssertEqual(none.highlightStops, ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame, tones: tones).highlightStops)
        let read = try XCTUnwrap(try reading(stock, model, none)
            .density(of: model.sample(density: highlight)))
        for record in 0..<3 { XCTAssertEqual(read[record], highlight[record], accuracy: 0.03) }
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
        func balance(_ tones: ApproximateNegativeScan.Tones) -> ApproximateNegativeScan.Balance {
            ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: 1,
                                            mode: .frame, tones: tones)
        }
        XCTAssertNotEqual(balance(.init(denseEnd: dense)).offset, .zero)
        let flat = SIMD3<Float>(0.03, 0.02, 0.04)
        XCTAssertEqual(balance(.init(denseEnd: flat)).offset, .zero)
        XCTAssertNil(balance(.init(denseEnd: flat)).highlightStops)
        XCTAssertEqual(balance(.init()).offset, .zero)
        XCTAssertEqual(balance(.init(denseEnd: SIMD3(.nan, 1, 1))).offset, .zero)
        // An offset stops at the range a reading takes.
        let wild = balance(.init(denseEnd: SIMD3(0.1, 1.2, 3)))
        XCTAssertNoThrow(try reading(stock, model, wild))
        XCTAssertEqual(wild.offset.z, ApproximateNegativeScan.offsetRange.lowerBound)
    }

    func testABlackAndWhiteFilmHasNothingToBalance() throws {
        let stock = try stock("hp5plus400")
        let dense = SIMD3<Float>(0.9, 1.1, 1.3)
        let balance = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: dense))
        XCTAssertEqual(balance.offset, .zero)
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
        let roll = ApproximateNegativeScan.RollBalance(
            colour: [neutral.x / neutral.y, neutral.z / neutral.y], frames: 12, level: neutral.y)
        let sky = try dense(0.4, SIMD3(-0.2, 0, 0.3))
        func balance(_ mode: ApproximateNegativeScan.BalanceMode, _ end: SIMD3<Float>,
                     roll: ApproximateNegativeScan.RollBalance?,
                     picked: SIMD3<Float>? = nil) -> ApproximateNegativeScan.Balance {
            ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: 1, mode: mode,
                                            tones: .init(denseEnd: end, picked: picked), roll: roll)
        }
        let rolled = balance(.roll, sky, roll: roll)
        let own = balance(.frame, neutral, roll: nil).offset
        for record in 0..<3 { XCTAssertEqual(rolled.offset[record], own[record], accuracy: 1e-5) }
        XCTAssertEqual(rolled.offset, balance(.roll, neutral, roll: roll).offset)
        // Each frame's print is still timed on its own highlights.
        XCTAssertEqual(rolled.highlightStops, balance(.frame, sky, roll: nil).highlightStops)
        XCTAssertNotEqual(rolled.highlightStops, balance(.roll, neutral, roll: roll).highlightStops)
        // A neutral picked on the frame is the frame's, not the roll's.
        XCTAssertEqual(balance(.roll, sky, roll: roll, picked: sky).offset, rolled.offset)
        // The frame's own balance leaves the roll's neutral alone, and no balance leaves both.
        XCTAssertEqual(balance(.frame, sky, roll: roll).offset, balance(.frame, sky, roll: nil).offset)
        XCTAssertEqual(balance(.none, sky, roll: roll).offset, .zero)
        // Without a roll the frame is balanced on its own.
        XCTAssertEqual(balance(.roll, sky, roll: nil), balance(.frame, sky, roll: nil))
        XCTAssertEqual(balance(.roll, sky, roll: nil, picked: neutral).offset, own)
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
        XCTAssertEqual(rolled.offset, own.offset)
        XCTAssertEqual(rolled.gains, .one)
        // A frame that cannot be read has no level to take the roll's colour at.
        XCTAssertEqual(ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .roll, tones: .init(), roll: old).offset,
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
