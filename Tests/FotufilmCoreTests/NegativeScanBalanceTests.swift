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
            tones: .init(denseEnd: neutral, neutral: neutral))
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
        let tones = ApproximateNegativeScan.Tones(denseEnd: neutral, neutral: neutral)
        let none = ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: 1,
                                                   mode: .none, tones: tones)
        XCTAssertEqual(none.offset, .zero)
        XCTAssertEqual(none.highlightStops, ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame, tones: tones).highlightStops)
        let read = try XCTUnwrap(try reading(stock, model, none)
            .density(of: model.sample(density: highlight)))
        for record in 0..<3 { XCTAssertEqual(read[record], highlight[record], accuracy: 0.03) }
    }

    func testAPickedNeutralTakesTheFoundOnesPlace() throws {
        let stock = try stock("portra400")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let found = try XCTUnwrap(model.scannerDensity(
            density: NegativeScanModel.density(stock: stock, logExposure: 0.6)))
        let midtone = NegativeScanModel.density(stock: stock, logExposure: -0.2, shift: cast)
        let picked = try XCTUnwrap(model.scannerDensity(density: midtone))
        let balance = ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: found, neutral: found, picked: picked))
        let read = try XCTUnwrap(try reading(stock, model, balance)
            .density(of: model.sample(density: midtone)))
        let expected = grey(stock, green: read.y)
        for record in 0..<3 { XCTAssertEqual(read[record], expected[record], accuracy: 0.002) }
        // The print is still timed on the highlights.
        XCTAssertEqual(balance.highlightStops, ApproximateNegativeScan.balance(
            stock: stock, setup: setup, separation: 1, mode: .frame,
            tones: .init(denseEnd: found, neutral: found)).highlightStops)
    }

    func testAFrameWithoutANeutralBalancesOnItsDensestEndOrNotAtAll() throws {
        let stock = try stock("gold200")
        let model = NegativeScanModel(stock: stock, setup: setup)
        let dense = try XCTUnwrap(model.scannerDensity(
            density: NegativeScanModel.density(stock: stock, logExposure: 0.6, shift: cast)))
        func balance(_ tones: ApproximateNegativeScan.Tones) -> ApproximateNegativeScan.Balance {
            ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: 1,
                                            mode: .frame, tones: tones)
        }
        XCTAssertEqual(balance(.init(denseEnd: dense)),
                       balance(.init(denseEnd: dense, neutral: dense)))
        // A frame too flat to tell, or one that cannot be read, is left as the film reads.
        let flat = SIMD3<Float>(0.03, 0.02, 0.04)
        XCTAssertEqual(balance(.init(denseEnd: flat, neutral: flat)).offset, .zero)
        XCTAssertNil(balance(.init(denseEnd: flat, neutral: flat)).highlightStops)
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
            tones: .init(denseEnd: dense, neutral: dense))
        XCTAssertEqual(balance.offset, .zero)
        XCTAssertNotNil(balance.highlightStops)
    }
}
