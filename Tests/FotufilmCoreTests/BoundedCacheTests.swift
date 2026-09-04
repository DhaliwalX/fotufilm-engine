import XCTest
@testable import FotufilmCore

final class BoundedCacheTests: XCTestCase {

    func testHoldsNoMoreThanItsLimitAndDropsTheLeastRecentlyUsed() {
        var cache = BoundedCache<Int, String>(limit: 3)
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        cache.insert("c", for: 3)
        // Reading 1 makes it the most recent; 2 is now the oldest.
        XCTAssertEqual(cache.value(for: 1), "a")
        cache.insert("d", for: 4)

        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.value(for: 2))
        XCTAssertEqual(cache.value(for: 1), "a")
        XCTAssertEqual(cache.value(for: 3), "c")
        XCTAssertEqual(cache.value(for: 4), "d")
    }

    func testReinsertingAKeyReplacesWithoutGrowing() {
        var cache = BoundedCache<Int, Int>(limit: 2)
        cache.insert(10, for: 1)
        cache.insert(20, for: 2)
        cache.insert(11, for: 1)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(for: 1), 11)
        cache.insert(30, for: 3)
        // 2 was the least recent: 1 was refreshed by its replacement.
        XCTAssertNil(cache.value(for: 2))
        XCTAssertEqual(cache.value(for: 1), 11)
    }

    /// A film aged by a slider is a different stock at every position, and each position used to
    /// keep its own table set for the life of the process — the memory a long editing session
    /// was spent on. The runtime now holds a working set and no more.
    func testSpectralTablesStopGrowingAcrossAgedStocks() {
        let stock = TestStocks.negative
        let before = SpectralRuntime.retainedTables.sets
        var distinct = Set<UInt64>()
        for step in 1...60 {
            let aged = stock.expired(years: Float(step) * 0.1)
            distinct.insert(SpectralRuntime.cacheIdentifier(for: aged))
            _ = SpectralRuntime.tables(for: aged)
        }
        XCTAssertEqual(distinct.count, 60, "every age is its own table set")
        let after = SpectralRuntime.retainedTables.sets
        XCTAssertLessThanOrEqual(after, 40)
        XCTAssertGreaterThanOrEqual(after, min(40, before + 1))
    }
}
