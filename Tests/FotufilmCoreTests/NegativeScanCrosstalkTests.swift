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
            let sensitivity = NegativeScanCrosstalk.whiteSensitivities[i]
            passed += sensitivity * pow(10, -density)
            total += sensitivity
        }
        return border * passed / total
    }

    private let white = NegativeScanCrosstalk.Correction(strength: 1, light: .white)

    private func weights(_ id: String, _ correction: NegativeScanCrosstalk.Correction,
                         neutral: SIMD3<Float>? = nil) throws -> [SIMD3<Float>] {
        NegativeScanCrosstalk.weights(for: try stock(id), correction: correction, neutral: neutral)
    }

    func testNoCorrectionReadsEachRecordFromItsOwnChannel() throws {
        XCTAssertEqual(try weights("portra400", .none), identity)
        XCTAssertEqual(NegativeScanCrosstalk.plainWeights(correction: .none, neutral: nil), identity)
        // A black-and-white film has one dye: every record reads green, corrected or not.
        XCTAssertEqual(try weights("hp5plus400", white), Array(repeating: SIMD3(0, 1, 0), count: 3))
    }

    /// Without a frame to read, every row sums to one, keeping equal densities; half the
    /// correction is halfway to the full one.
    func testRowsSumToOneAndBlendFromTheIdentity() throws {
        for id in ["portra400", "gold200", "vision500t", "superia400"] {
            let full = try weights(id, white)
            let half = try weights(id, .init(strength: 0.5, light: .white))
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

    /// The frame's densest end, which its balance takes as a neutral highlight, reads as it did,
    /// so the film's greys along it stay grey; the rows still take the other dyes out.
    func testTheFramesGreyKeepsItsDensities() throws {
        let neutral = SIMD3<Float>(1.05, 1.3, 1.15)
        let held = try weights("gold200", white, neutral: neutral)
        let summed = try weights("gold200", white)
        let read = NegativeScanCrosstalk.apply(held, neutral)
        for c in 0..<3 { XCTAssertEqual(read[c], neutral[c], accuracy: 1e-5) }
        let half = NegativeScanCrosstalk.apply(
            try weights("gold200", .init(strength: 0.5, light: .white), neutral: neutral), neutral)
        for c in 0..<3 { XCTAssertEqual(half[c], neutral[c], accuracy: 1e-5) }
        for r in 0..<3 { for c in 0..<3 where c != r {
            XCTAssertEqual(held[r][c] / held[r][r], summed[r][c] / summed[r][r], accuracy: 1e-5)
        } }
        // A densest end no row can keep within a factor of two falls back to equal densities.
        XCTAssertEqual(try weights("gold200", white, neutral: SIMD3(0.1, 3, 0.1)), summed)
    }

    /// Narrowband LEDs see far less of the other dyes than a camera under white light.
    func testNarrowbandLightHasLessCrosstalkToUndo() throws {
        let rgb = try weights("gold200", .init(strength: 1, light: .rgb))
        let camera = try weights("gold200", white)
        for r in 0..<3 {
            let off = { (w: [SIMD3<Float>]) in (0..<3).filter { $0 != r }.map { abs(w[r][$0]) }.reduce(0, +) }
            XCTAssertLessThan(off(rgb), 0.5 * off(camera), "record \(r)")
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
        let reading = try ApproximateNegativeScan(stock: stock, border: border,
                                                  weights: try weights("portra400", white))
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
            let reading = try ApproximateNegativeScan(
                stock: stock, border: border,
                weights: try weights("portra400", .init(strength: crosstalk, light: .white)))
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
                                                  weights: try weights("superia400", white))
        let sample = SIMD3(reading.maximumSample[0] * 0.999, reading.minimumSample[1] * 1.001,
                           reading.maximumSample[2] * 0.999)
        let density = try XCTUnwrap(reading.density(of: sample))
        for r in 0..<3 { XCTAssertTrue(NegativeInterchange.range.contains(density[r])) }
        XCTAssertThrowsError(try ApproximateNegativeScan(
            stock: try stock("gold200"), border: border,
            weights: [SIMD3(1, 0, 0), SIMD3(0, .nan, 0), SIMD3(0, 0, 1)]))
    }

    /// The correction keeps the frame's densest end, so the frame is timed and balanced as it was,
    /// and the balance carries the weights its reading takes.
    func testTheBalanceIsTheFramesOwnAndCarriesTheWeights() throws {
        let stock = try stock("gold200")
        let dense = SIMD3<Float>(1.0, 1.3, 1.1)
        let plain = ApproximateNegativeScan.balance(stock: stock, denseEnd: dense)
        let corrected = ApproximateNegativeScan.balance(stock: stock, denseEnd: dense, correction: white)
        for c in 0..<3 { XCTAssertEqual(corrected.gains[c], plain.gains[c], accuracy: 1e-4) }
        XCTAssertEqual(try XCTUnwrap(corrected.highlightStops), try XCTUnwrap(plain.highlightStops),
                       accuracy: 1e-4)
        XCTAssertEqual(corrected.weights, try weights("gold200", white, neutral: dense))
        XCTAssertNil(ApproximateNegativeScan.balance(stock: stock, denseEnd: dense,
                                                     correction: .none).weights)
        // A frame too small to read still separates its colours, keeping equal densities.
        XCTAssertEqual(ApproximateNegativeScan.balance(stock: stock, denseEnd: nil, correction: white),
                       ApproximateNegativeScan.Balance(gains: .one, highlightStops: nil,
                                                       weights: try weights("gold200", white)))
    }

    /// The kernels are handed the weights row by row after the reading.
    func testThePackedReadingCarriesTheWeights() throws {
        let reading = try ApproximateNegativeScan(
            stock: try stock("gold200"), border: border,
            weights: try weights("gold200", .init(strength: 0.7, light: .white)))
        let packed = ApproximateNegativeScan.packedReading(reading)
        let offset = Int(FOTUFILM_CONFIG_SCAN_CROSSTALK - FOTUFILM_CONFIG_SCAN_READING)
        XCTAssertEqual(packed.count, offset + 9)
        for r in 0..<3 { for c in 0..<3 {
            XCTAssertEqual(packed[offset + r * 3 + c], reading.weights[r][c])
        } }
        XCTAssertEqual(ApproximateNegativeScan.packedReading(nil), [Float](repeating: 0, count: offset + 9))
    }

    /// The browser reads a scan without a film with these weights before it keeps the frame's
    /// densest end (web/src/negative-reading.js PLAIN_CROSSTALK).
    func testThePlainWeightsAreTheBrowsers() {
        let browser: [NegativeScanCrosstalk.Light: [SIMD3<Float>]] = [
            .white: [SIMD3(1.8741934, -0.8167563, -0.057437092),
                     SIMD3(-0.07067131, 1.0591061, 0.011565179),
                     SIMD3(0.0047098156, -0.04486931, 1.0401592)],
            .rgb: [SIMD3(1.014058, -0.014435816, 0.00037779874),
                   SIMD3(-1.604771e-05, 1.0268912, -0.02687511),
                   SIMD3(7.733554e-09, -0.0008941038, 1.0008941)],
        ]
        for light in NegativeScanCrosstalk.Light.allCases {
            let weights = NegativeScanCrosstalk.plainWeights(
                correction: .init(strength: 1, light: light), neutral: nil)
            for r in 0..<3 { for c in 0..<3 {
                XCTAssertEqual(weights[r][c], browser[light]![r][c], accuracy: 1e-5, "\(light)")
            } }
        }
    }
}
