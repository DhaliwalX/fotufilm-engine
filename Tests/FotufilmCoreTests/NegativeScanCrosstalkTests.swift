import XCTest
import FotufilmHalide
@testable import FotufilmCore

final class NegativeScanCrosstalkTests: XCTestCase {
    private let border = SIMD3<Float>(0.82, 0.41, 0.19)
    private let identity = [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]

    private func stock(_ id: String) throws -> FilmStock {
        try XCTUnwrap(FilmStock.presets[id])
    }

    /// The scan of film holding `amounts` of each dye over its base: what each Rec. 2020 channel
    /// passes, integrated over the spectrum as the correction models it.
    private func scan(_ amounts: SIMD3<Float>, dyes: [[Float]]) -> SIMD3<Float> {
        var passed = SIMD3<Float>.zero, total = SIMD3<Float>.zero
        for i in 0..<SpectralGrid.count {
            let density = amounts.x * dyes[0][i] + amounts.y * dyes[1][i] + amounts.z * dyes[2][i]
            let sensitivity = NegativeScanCrosstalk.sensitivities[i]
            passed += sensitivity * pow(10, -density)
            total += sensitivity
        }
        return border * passed / total
    }

    func testNoCorrectionReadsEachRecordFromItsOwnChannel() throws {
        XCTAssertEqual(NegativeScanCrosstalk.weights(for: try stock("portra400"), strength: 0), identity)
        XCTAssertEqual(NegativeScanCrosstalk.plainWeights(strength: 0), identity)
        // A black-and-white film has one dye: every record reads green, corrected or not.
        XCTAssertEqual(NegativeScanCrosstalk.weights(for: try stock("hp5plus400"), strength: 1),
                       Array(repeating: SIMD3(0, 1, 0), count: 3))
    }

    /// Every row sums to one at every strength, so a neutral the scan reads stays neutral, and
    /// half the correction is halfway to the full one.
    func testRowsSumToOneAndBlendFromTheIdentity() throws {
        for id in ["portra400", "gold200", "vision500t", "superia400"] {
            let full = NegativeScanCrosstalk.weights(for: try stock(id), strength: 1)
            let half = NegativeScanCrosstalk.weights(for: try stock(id), strength: 0.5)
            for r in 0..<3 {
                XCTAssertEqual(full[r].sum(), 1, accuracy: 1e-5, id)
                XCTAssertEqual(half[r].sum(), 1, accuracy: 1e-5, id)
                XCTAssertGreaterThan(full[r][r], 1, "\(id) record \(r) gains its own channel")
                for c in 0..<3 {
                    XCTAssertEqual(half[r][c], (identity[r][c] + full[r][c]) / 2, accuracy: 1e-6)
                }
            }
        }
    }

    /// Without correction the reading is the film's base less its gain times each channel's
    /// log over the border, as it always was.
    func testNoCorrectionIsTheOneChannelReading() throws {
        let stock = try stock("gold200")
        let gains = SIMD3<Float>(0.9, 1, 1.2)
        let reading = try ApproximateNegativeScan(stock: stock, border: border, gains: gains)
        let sample = border * SIMD3(0.2, 0.31, 0.47)
        let density = try XCTUnwrap(reading.density(of: sample))
        for r in 0..<3 {
            XCTAssertEqual(density[r], stock.curves[r].dMin - gains[r] * log10(sample[r] / border[r]))
        }
    }

    /// A neutral reads neutral at full correction: each record its base plus the same density.
    func testANeutralStaysNeutral() throws {
        let stock = try stock("portra400")
        let reading = try ApproximateNegativeScan(stock: stock, border: border, crosstalk: 1)
        let density = try XCTUnwrap(reading.density(of: border * pow(10, -0.8)))
        for r in 0..<3 { XCTAssertEqual(density[r] - stock.curves[r].dMin, 0.8, accuracy: 1e-5) }
    }

    /// Magenta dye alone darkens the red channel too, which reads as cyan in a one-channel
    /// reading. Full correction takes nearly all of it back out of the red record where the
    /// linear model holds, and most of it from a dense patch of the one dye.
    func testFullCorrectionSeparatesOneDyeFromTheOtherRecords() throws {
        let stock = try stock("portra400")
        func overBase(_ amount: Float, _ crosstalk: Float) throws -> SIMD3<Float> {
            let sample = scan(SIMD3(0, amount, 0), dyes: stock.spectralProfile.imageDyeDensity)
            let reading = try ApproximateNegativeScan(stock: stock, border: border, crosstalk: crosstalk)
            let density = try XCTUnwrap(reading.density(of: sample))
            return density - SIMD3((0..<3).map { stock.curves[$0].dMin })
        }
        let plain = try overBase(0.2, 0), separated = try overBase(0.2, 1)
        XCTAssertGreaterThan(plain.x, 0.04, "the red channel sees the magenta dye")
        XCTAssertLessThan(abs(separated.x), 0.2 * plain.x)
        XCTAssertGreaterThan(separated.y, plain.y)
        XCTAssertLessThan(abs(try overBase(0.6, 1).x), 0.5 * (try overBase(0.6, 0).x))
    }

    /// Whatever a correction asks of a sample inside the usable range, the density stays in the
    /// interchange's range.
    func testDensityStaysInsideTheInterchange() throws {
        let reading = try ApproximateNegativeScan(stock: try stock("superia400"), border: border,
                                                  crosstalk: 1)
        let sample = SIMD3(reading.maximumSample[0] * 0.999, reading.minimumSample[1] * 1.001,
                           reading.maximumSample[2] * 0.999)
        let density = try XCTUnwrap(reading.density(of: sample))
        for r in 0..<3 { XCTAssertTrue(NegativeInterchange.range.contains(density[r])) }
        XCTAssertThrowsError(try ApproximateNegativeScan(stock: try stock("gold200"), border: border,
                                                         crosstalk: 1.5))
    }

    /// The balance reads the frame's densest end as the frame is read: a neutral highlight is
    /// still balanced to the film's own colour.
    func testTheBalanceReadsTheCorrectedDenseEnd() throws {
        let stock = try stock("gold200")
        let dense = SIMD3<Float>(1.2, 1.2, 1.2)
        XCTAssertEqual(ApproximateNegativeScan.balance(stock: stock, denseEnd: dense, crosstalk: 1),
                       ApproximateNegativeScan.balance(stock: stock, denseEnd: dense))
        let coloured = SIMD3<Float>(1.0, 1.3, 1.1)
        XCTAssertNotEqual(ApproximateNegativeScan.balance(stock: stock, denseEnd: coloured, crosstalk: 1),
                          ApproximateNegativeScan.balance(stock: stock, denseEnd: coloured))
    }

    /// The kernels are handed the weights row by row after the reading.
    func testThePackedReadingCarriesTheWeights() throws {
        let reading = try ApproximateNegativeScan(stock: try stock("gold200"), border: border,
                                                  crosstalk: 0.7)
        let packed = ApproximateNegativeScan.packedReading(reading)
        let offset = Int(FOTUFILM_CONFIG_SCAN_CROSSTALK - FOTUFILM_CONFIG_SCAN_READING)
        XCTAssertEqual(packed.count, offset + 9)
        for r in 0..<3 { for c in 0..<3 {
            XCTAssertEqual(packed[offset + r * 3 + c], reading.weights[r][c])
        } }
        XCTAssertEqual(ApproximateNegativeScan.packedReading(nil), [Float](repeating: 0, count: offset + 9))
    }

    /// The browser reads a scan without a film with these weights
    /// (web/src/negative-reading.js PLAIN_CROSSTALK).
    func testThePlainWeightsAreTheBrowsers() {
        let browser: [SIMD3<Float>] = [SIMD3(1.8741934, -0.8167563, -0.057437092),
                                       SIMD3(-0.07067131, 1.0591061, 0.011565179),
                                       SIMD3(0.0047098156, -0.04486931, 1.0401592)]
        let weights = NegativeScanCrosstalk.plainWeights(strength: 1)
        for r in 0..<3 { for c in 0..<3 { XCTAssertEqual(weights[r][c], browser[r][c], accuracy: 1e-5) } }
    }
}
