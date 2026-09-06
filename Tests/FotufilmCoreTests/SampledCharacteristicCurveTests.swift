import XCTest
@testable import FotufilmCore

final class SampledCharacteristicCurveTests: XCTestCase {
    func testNonuniformSamplesAndLocalExtremaArePreservedWithoutOvershoot() throws {
        let samples = try SampledCharacteristicCurve(
            logExposure: [-2, -1.25, 0.2, 0.8, 2], density: [0.1, 0.6, 0.5, 1.1, 1.5])
        for i in samples.logExposure.indices {
            XCTAssertEqual(samples.value(at: samples.logExposure[i]), samples.density[i])
        }
        for i in 0..<(samples.logExposure.count - 1) {
            let low = min(samples.density[i], samples.density[i + 1])
            let high = max(samples.density[i], samples.density[i + 1])
            for step in 0...100 {
                let x = samples.logExposure[i] + Float(step) / 100
                    * (samples.logExposure[i + 1] - samples.logExposure[i])
                XCTAssertGreaterThanOrEqual(samples.value(at: x), low - 1e-6)
                XCTAssertLessThanOrEqual(samples.value(at: x), high + 1e-6)
            }
        }
        XCTAssertEqual(samples.value(at: -20), 0.1)
        XCTAssertEqual(samples.value(at: 20), 1.5)
        // Both endpoints join constant tails, and every internal knot has one tangent.
        for x in samples.logExposure {
            let h: Float = 0.0005
            let left = (samples.value(at: x) - samples.value(at: x - h)) / h
            let right = (samples.value(at: x + h) - samples.value(at: x)) / h
            XCTAssertEqual(left, right, accuracy: 0.005, "slope continuity at \(x)")
        }
    }

    func testAgeingAndReciprocityTranslateEverySample() throws {
        var stock = try XCTUnwrap(FilmStock.named("gold200"))
        stock.reciprocityFailure = ReciprocityFailure(
            thresholdSeconds: 1, lostStopsPerDecade: 1)
        for changed in [stock.expired(years: 20), stock.reciprocity(shutterSeconds: 100)] {
            for channel in 0..<3 {
                let original = try XCTUnwrap(stock.curves[channel].sampled)
                let shifted = try XCTUnwrap(changed.curves[channel].sampled)
                let shift = changed.curves[channel].toe - stock.curves[channel].toe
                let fog = changed.curves[channel].dMin - stock.curves[channel].dMin
                for i in original.logExposure.indices {
                    XCTAssertEqual(shifted.logExposure[i], original.logExposure[i] + shift, accuracy: 1e-6)
                    XCTAssertEqual(changed.curves[channel].density(logExposure: shifted.logExposure[i]),
                                   original.density[i] + fog, accuracy: 1e-6)
                }
            }
        }
    }

    func testInvalidSamplesAreRejectedAndSerializationPreservesPoints() throws {
        let invalid: [([Float], [Float])] = [([0], [0]), ([0, 0], [0, 1]),
              ([1, 0], [0, 1]), ([0, 1], [0]), ([0, .nan], [0, 1]),
              ([0, 1], [0, .infinity])]
        for (x, y) in invalid {
            XCTAssertThrowsError(try SampledCharacteristicCurve(logExposure: x, density: y))
        }
        let original = try SampledCharacteristicCurve(logExposure: [-1, 0, 2], density: [0, 1, 2])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SampledCharacteristicCurve.self, from: data)
        XCTAssertEqual(original.logExposure, restored.logExposure)
        XCTAssertEqual(original.density, restored.density)
        XCTAssertEqual(original.slopes, restored.slopes)
    }

    func testReleasedRecordsPassThroughEverySample() throws {
        let sampled = FilmStock.presetIDs.compactMap(FilmStock.named)
            .filter { $0.curves.contains { $0.sampled != nil } }
        XCTAssertEqual(sampled.count, 33)
        var count = 0
        for stock in sampled {
            for curve in stock.curves {
                let record = try XCTUnwrap(curve.sampled, stock.name)
                for i in record.logExposure.indices {
                    XCTAssertEqual(curve.density(logExposure: record.logExposure[i]),
                                   record.density[i], "\(stock.name), point \(i)")
                    count += 1
                }
            }
        }
        XCTAssertGreaterThan(count, 30_000)
    }

    func testPackedRuntimeUsesSamePointsAndInterpolatedValues() throws {
        let stock = try XCTUnwrap(FilmStock.named("provia100f"))
        var configuration = [Float](repeating: 0, count: FilmEngineInvocation.configurationCount)
        for (channel, curve) in stock.curves.enumerated() {
            let record = try XCTUnwrap(curve.sampled)
            let base = FilmEngineInvocation.sampledCurvesOffset
                + channel * FilmEngineInvocation.sampledCurveStride
            configuration[base] = Float(record.logExposure.count)
            for i in record.logExposure.indices {
                configuration[base + 1 + i * 3] = record.logExposure[i]
                configuration[base + 2 + i * 3] = record.density[i]
                configuration[base + 3 + i * 3] = record.slopes[i]
            }
            for i in 0..<(record.logExposure.count - 1) {
                for fraction in [Float(0), 0.37, 1] {
                    let x = record.logExposure[i] + fraction
                        * (record.logExposure[i + 1] - record.logExposure[i])
                    XCTAssertEqual(try XCTUnwrap(FilmEngineInvocation.sampledFilmDensity(
                        configuration: configuration, channel: channel, logExposure: x)),
                        curve.density(logExposure: x), accuracy: 1e-6)
                }
            }
        }
    }

    func testSampledRecordsRequireNewSchemaAndAffectCacheIdentity() throws {
        var definition = try XCTUnwrap(FilmStock.presetDefinitions["gold200"])
        try definition.validate()
        definition.schemaVersion = 1
        XCTAssertThrowsError(try definition.validate())
        let original = definition.stock
        var changed = original
        let record = try XCTUnwrap(changed.curves[0].sampled)
        var density = record.density
        density[density.count / 2] += 0.01
        changed.curves[0].sampled = try SampledCharacteristicCurve(
            logExposure: record.logExposure, density: density)
        XCTAssertNotEqual(SpectralRuntime.cacheIdentifier(for: original),
                          SpectralRuntime.cacheIdentifier(for: changed))
    }
}
