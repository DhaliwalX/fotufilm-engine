import XCTest
@testable import FotufilmEditModel

final class ProUnlockTests: XCTestCase {

    func testFreeSetIsTheDecidedThree() {
        XCTAssertEqual(ProUnlock.freeStockIDs, ["gold200", "trix400", "astia100f"])
    }

    func testFreeStockIDsNameShippedPacks() throws {
        guard let dir = ProcessInfo.processInfo.environment["FOTUFILM_STOCKS"] else {
            throw XCTSkip("stock sheets not available without FOTUFILM_STOCKS")
        }
        let shipped = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
        for id in ProUnlock.freeStockIDs {
            XCTAssertTrue(shipped.contains(id), "\(id) is free but not shipped")
        }
    }

    func testFreeUserGetsExactlyTheFreeStocks() {
        for id in ProUnlock.freeStockIDs {
            XCTAssertTrue(ProUnlock.allowsStock(id: id, isPro: false))
        }
        XCTAssertFalse(ProUnlock.allowsStock(id: "portra400", isPro: false))
        XCTAssertFalse(ProUnlock.allowsStock(id: "vision250d", isPro: false))
    }

    func testProUserGetsEveryStock() {
        for id in ProUnlock.freeStockIDs + ["portra400", "vision250d", "delta3200"] {
            XCTAssertTrue(ProUnlock.allowsStock(id: id, isPro: true))
        }
    }

    // MARK: - What the sheet claims

    func testUnlockedCountExcludesTheFreeFilms() {
        let pack = ["gold200", "trix400", "astia100f",
                    "portra400", "velvia50", "vision250d"]
        XCTAssertEqual(ProUnlock.unlockedFilmCount(builtInIDs: pack), 3)
        XCTAssertEqual(ProUnlock.unlockedFilmCount(builtInIDs: [String]()), 0)
    }

    func testApproximateCountRoundsDown() {
        XCTAssertEqual(ProUnlock.approximateFilmCount(23), "20+")
        XCTAssertEqual(ProUnlock.approximateFilmCount(37), "35+")
        XCTAssertEqual(ProUnlock.approximateFilmCount(27), "25+")
        XCTAssertEqual(ProUnlock.approximateFilmCount(30), "30+")
    }

    func testSmallCatalogueIsStatedExactly() {
        for count in 0...4 {
            XCTAssertEqual(ProUnlock.approximateFilmCount(count), "\(count)")
        }
        XCTAssertEqual(ProUnlock.approximateFilmCount(-3), "0")
    }

    func testTheClaimNeverOverstatesThePack() {
        for count in 0...400 {
            let said = ProUnlock.approximateFilmCount(count)
            let number = Int(said.replacingOccurrences(of: "+", with: "")) ?? -1
            XCTAssertLessThanOrEqual(number, count,
                                     "claimed \(said) with \(count) films")
        }
    }

    func testEveryFeatureFollowsThePurchase() {
        for feature in ProUnlock.Feature.allCases {
            XCTAssertFalse(ProUnlock.allows(feature, isPro: false),
                           "\(feature) is open without the purchase")
            XCTAssertTrue(ProUnlock.allows(feature, isPro: true),
                          "\(feature) is closed after the purchase")
        }
    }
}
