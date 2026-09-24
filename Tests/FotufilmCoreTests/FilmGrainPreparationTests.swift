import Foundation
import XCTest
@testable import FotufilmCore

final class FilmGrainPreparationTests: XCTestCase {
    func testParallelCalibrationMatchesOriginalSerialBits() {
        let side = FilmGrain.tileSide
        let flat = [Float](repeating: 0.8, count: side * side)
        let patterned = (0..<(side * side)).map { index in
            Float((index % side / 7 + index / side / 9) % 5) * 0.07 + 0.25
        }
        let subtle = patterned.map { Float(0.8) + $0 * 0.00001 }
        let grain = FilmGrain(stock: TestStocks.negative)
        let film = grain.tileLight(record: 1, gross: 0.8, seed: FilmGrain.tileSeed)
        var serialSeconds = 0.0, parallelSeconds = 0.0
        for (label, light) in [("flat", flat), ("patterned", patterned), ("subtle", subtle), ("film", film)] {
            var start = Date.timeIntervalSinceReferenceDate
            let expected = serialSigma(light)
            serialSeconds += Date.timeIntervalSinceReferenceDate - start
            start = Date.timeIntervalSinceReferenceDate
            let actual = FilmGrain.tileSigma48(light)
            parallelSeconds += Date.timeIntervalSinceReferenceDate - start
            XCTAssertEqual(actual.bitPattern, expected.bitPattern, label)
        }
        print(String(format: "FilmPreparation covariance serial_ms=%.3f parallel_ms=%.3f speedup=%.2f",
            serialSeconds * 1_000, parallelSeconds * 1_000, serialSeconds / parallelSeconds))
    }

    func testTwoConcurrentLevelsKeepEveryCanonicalBankBit() {
        for (label, stock) in [("negative", TestStocks.negative), ("monochrome", TestStocks.monochrome),
                               ("reversal", TestStocks.reversal)] {
            let grain = FilmGrain(stock: stock)
            var start = Date.timeIntervalSinceReferenceDate
            let serial = grain.buildTiles(seed: FilmGrain.tileSeed, parallel: false)
            let serialSeconds = Date.timeIntervalSinceReferenceDate - start
            start = Date.timeIntervalSinceReferenceDate
            let parallel = grain.buildTiles(seed: FilmGrain.tileSeed, parallel: true)
            let parallelSeconds = Date.timeIntervalSinceReferenceDate - start
            let expected = serial.packed(), actual = parallel.packed()
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertTrue(zip(actual, expected).allSatisfy { $0.bitPattern == $1.bitPattern },
                "\(label) canonical summed-area bank")
            XCTAssertEqual(parallel.levels.map { $0.map { $0.meanLight.bitPattern } },
                serial.levels.map { $0.map { $0.meanLight.bitPattern } }, "\(label) means")
            print(String(format: "FilmPreparation bank=%@ floats=%d serial_ms=%.3f parallel_ms=%.3f speedup=%.2f",
                label, actual.count, serialSeconds * 1_000, parallelSeconds * 1_000,
                serialSeconds / parallelSeconds))
        }
    }

    /// The original production reduction, kept as the exact ordering oracle. Do not parallelize
    /// or algebraically simplify this reference alongside the implementation under test.
    private func serialSigma(_ light: [Float]) -> Float {
        let n = FilmGrain.tileSide
        var total = 0.0
        for t in light { total += Double(t) }
        let mean = total / Double(n * n)
        let d = light.map { Double($0) - mean }
        let reach = 16
        var power = 0.0
        for dy in -reach...reach {
            for dx in -reach...reach {
                var c = 0.0
                for y in 0..<n {
                    let row = y * n, other = ((y + dy + n) % n) * n
                    for x in 0..<n { c += d[row + x] * d[other + (x + dx + n) % n] }
                }
                power += c / Double(n * n)
            }
        }
        let radius = Double(FilmStock.granularityApertureRadiusMM / FilmGrain.tileTexelMM)
        let lightVariance = max(power, 0) / (Double.pi * radius * radius)
        return Float(lightVariance.squareRoot() / (mean * 2.302_585_093))
    }
}
