import Foundation
import XCTest
@testable import FotufilmCore

final class FilmGrainAssetTests: XCTestCase {
    func testPopulationAndEveryBankBitRoundTripIncludingNondefaultLook() throws {
        for stock in [TestStocks.negative, TestStocks.monochrome, TestStocks.reversal] {
            let identity = FilmGrainAsset.identity(stock: stock)
            let original = FilmGrain(stock: stock, useCachedAnchor: false, checkCancellation: {})
            let bytes = try FilmGrainAsset.encode(grain: original, identity: identity,
                tiles: original.buildTiles(seed: FilmGrain.tileSeed))
            let restored = try FilmGrainAsset.decode(bytes, identity: identity)
            XCTAssertEqual(try FilmGrainAsset.encode(grain: restored, identity: identity), bytes,
                           "Every population, density bound, mean and SAT bit must round trip")
            XCTAssertTrue(zip(original.tiles().packed(), restored.tiles().packed())
                .allSatisfy { $0.bitPattern == $1.bitPattern })
            let look = FilmGrain.Look(layers: SIMD3(0.6, 1, 1.4), colour: 0.4, size: 1.7, softness: 1.5)
            for pitch: Float in [137, 611] {
                let expected = original.configurationBlock(pxPerMM: pitch, amount: 0.83, look: look, id: 1)
                let actual = restored.configurationBlock(pxPerMM: pitch, amount: 0.83, look: look, id: 1)
                XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern), stock.name)
            }
        }
    }

    func testIdentityCoversCurveShapeSamplesReferenceAndPopulation() throws {
        let base = TestStocks.negative
        let expected = FilmGrainAsset.identity(stock: base)
        var shape = base
        shape.curves[0].toeWidth = shape.curves[0].toeWidth.nextUp
        XCTAssertEqual(shape.curves[0].dMax, base.curves[0].dMax)
        XCTAssertNotEqual(FilmGrainAsset.identity(stock: shape), expected)
        var secondary = base
        secondary.curves[1].secondary = .init(gamma: 0.2, toe: -1, toeWidth: 0.1,
                                              shoulder: 1, shoulderWidth: 0.2)
        XCTAssertNotEqual(FilmGrainAsset.identity(stock: secondary), expected)
        var sampled = base
        sampled.curves[0].sampled = try .init(logExposure: [-2, 0, 2], density: [0.1, 1, 2])
        let first = FilmGrainAsset.identity(stock: sampled)
        sampled.curves[0].sampled = try .init(logExposure: [-2, 0, 2], density: [0.1, 1.1, 2])
        XCTAssertNotEqual(FilmGrainAsset.identity(stock: sampled), first)
        XCTAssertNotEqual(FilmGrainAsset.identity(stock: base, reference: base),
                          FilmGrainAsset.identity(stock: base, reference: shape))
        var population = base
        let previous = base.crystalGrainPopulation
        population.crystalGrainPopulation = .init(radiusSpan: previous.radiusSpan,
            sublayerShares: previous.sublayerShares, coatingDensityScale: 1.3)
        XCTAssertNotEqual(FilmGrainAsset.identity(stock: population), expected)
    }

    func testRejectsStaleMalformedNonfiniteAndSlicedDataIsValid() throws {
        let stock = TestStocks.monochrome
        let identity = FilmGrainAsset.identity(stock: stock)
        let bytes = try FilmGrainAsset.generate(stock: stock)
        var sliced = Data([0xFF])
        sliced.append(bytes)
        let decoded = try FilmGrainAsset.decode(sliced.dropFirst(), identity: identity)
        XCTAssertEqual(try FilmGrainAsset.encode(grain: decoded, identity: identity), bytes)
        var wrongHeader = bytes
        wrongHeader[0] = 0
        var nonfinite = bytes
        // Last populated record is followed by the empty blue-record count. Replace its last SAT
        // value with a quiet NaN; a finite-data check must reject this independently of identity.
        nonfinite.replaceSubrange((nonfinite.count - 8)..<(nonfinite.count - 4),
                                  with: [0, 0, 0xC0, 0x7F])
        var hugeCount = bytes
        hugeCount.replaceSubrange(12..<16, with: [0xFF, 0xFF, 0xFF, 0x7F])
        for malformed in [Data(), wrongHeader, Data(bytes.dropLast()), bytes + Data([0]), nonfinite, hugeCount] {
            XCTAssertThrowsError(try FilmGrainAsset.decode(malformed, identity: identity))
        }
        XCTAssertThrowsError(try FilmGrainAsset.decode(bytes,
            identity: FilmGrainAsset.identity(stock: TestStocks.reversal)))
    }

    func testProviderAcceptanceAndMissingInvalidStaleFallback() throws {
        defer { FilmGrain.installAssetProvider(nil) }
        var stock = TestStocks.monochrome
        stock.name = "Asset provider \(UUID().uuidString)"
        let bytes = try FilmGrainAsset.generate(stock: stock)
        let identity = FilmGrainAsset.identity(stock: stock)
        FilmGrain.installAssetProvider { requested in requested == identity ? bytes : nil }
        let loaded = FilmGrain.binding(stock: stock, reference: nil, checkCancellation: {})
        XCTAssertTrue(loaded.usedAsset)
        XCTAssertEqual(try FilmGrainAsset.encode(grain: loaded.grain, identity: identity), bytes)
        // The generation API must ignore both an installed provider and a live asset binding.
        XCTAssertEqual(try FilmGrainAsset.generate(stock: stock), bytes)
        for (label, supplied) in [("missing", Optional<Data>.none), ("invalid", Data([1, 2, 3])),
                                  ("stale", bytes)] {
            var empty = TestStocks.negative
            empty.name = "Asset fallback \(label) \(UUID().uuidString)"
            empty.grainStrength = 0
            FilmGrain.installAssetProvider { _ in supplied }
            let fallback = FilmGrain.binding(stock: empty, reference: nil, checkCancellation: {})
            XCTAssertFalse(fallback.usedAsset, label)
            XCTAssertTrue(fallback.grain.records.allSatisfy { $0.sublayers.isEmpty }, label)
        }
    }

    func testCachedPopulationMatchesColdCalibrationBits() throws {
        var stock = TestStocks.negative
        stock.name = "Anchor association \(UUID().uuidString)"
        let cold = FilmGrain(stock: stock)
        let warm = FilmGrain(stock: stock)
        func populationBits(_ grain: FilmGrain) -> [UInt32] {
            grain.records.flatMap { record in
                [record.dMin, record.dMax].map(\.bitPattern) + record.sublayers.flatMap { layer in
                    [layer.coatedPerMM2, layer.sigmaMM, layer.peakDemand, layer.capacity, layer.edge,
                     layer.smallestSigmaMM, layer.dyePerCloudMM2, layer.cellMM, layer.voidIntegralMM2]
                        .map(\.bitPattern) + layer.forming.map(\.bitPattern)
                }
            }
        }
        XCTAssertTrue(populationBits(warm) == populationBits(cold),
                      "Cached calibration must retain every cold population bit")
    }
}
