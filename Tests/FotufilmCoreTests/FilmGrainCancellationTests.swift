import Foundation
import XCTest
@testable import FotufilmCore

final class FilmGrainCancellationTests: XCTestCase {
    func testCancelledAnchorDoesNotCacheAnUnfinishedPopulation() throws {
        var stock = TestStocks.monochrome
        stock.name = "Cancelled anchor \(UUID().uuidString)"
        var checks = 0
        XCTAssertThrowsError(try FilmGrain(stock: stock, useCachedAnchor: true) {
            checks += 1
            // Interrupt after the first measured calibration pass.
            if checks == 4 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
        let recovered = FilmGrain(stock: stock, useCachedAnchor: true, checkCancellation: {})
        let uncached = FilmGrain(stock: stock, useCachedAnchor: false, checkCancellation: {})
        XCTAssertEqual(try FilmGrainAsset.encode(grain: recovered, identity: Data()),
                       try FilmGrainAsset.encode(grain: uncached, identity: Data()))
    }

    func testCancelledTilesAreNotPublishedAndRetryCompletes() throws {
        var stock = TestStocks.monochrome
        stock.name = "Cancelled bank \(UUID().uuidString)"
        let grain = FilmGrain(stock: stock)
        var checks = 0
        XCTAssertThrowsError(try grain.tiles {
            checks += 1
            // tiles(), buildTiles(), first pair, then cancellation before the second pair.
            if checks == 4 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
        let recovered = grain.tiles(checkCancellation: {})
        XCTAssertEqual(recovered.levels[1].count, FilmGrain.tileLevels)
        let expected = grain.buildTiles(seed: FilmGrain.tileSeed, parallel: false)
        XCTAssertEqual(recovered.packed().map(\.bitPattern), expected.packed().map(\.bitPattern))
    }

    func testCachedReadsAndCancelledWaitersDoNotWaitForColdPreparation() async throws {
        var cachedStock = TestStocks.negative
        cachedStock.name = "Cached bank \(UUID().uuidString)"
        cachedStock.grainStrength = 0
        let cached = FilmGrain.binding(stock: cachedStock, reference: nil, checkCancellation: {})
        var coldStock = cachedStock
        coldStock.name = "Blocked cold bank \(UUID().uuidString)"
        let cold = coldStock
        let started = expectation(description: "Cold preparation started outside the registry lock")
        let release = DispatchSemaphore(value: 0)
        let preparing = Task.detached {
            var checks = 0
            return FilmGrain.binding(stock: cold, reference: nil) {
                checks += 1
                if checks == 2 {
                    started.fulfill()
                    // A bounded stand-in for a slow cold population build.
                    _ = release.wait(timeout: .now() + 5)
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        defer { release.signal() }
        let hit = expectation(description: "Cached lookup completes during cold preparation")
        let stock = cachedStock
        let lookup = Task.detached {
            let result = FilmGrain.binding(stock: stock, reference: nil, checkCancellation: {})
            hit.fulfill()
            return result
        }
        let stopped = expectation(description: "Cancelled waiter exits during cold preparation")
        let waitingStarted = expectation(description: "Waiter entered the busy registry")
        let waiting = Task.detached {
            var first = true
            do {
                _ = try FilmGrain.binding(stock: cold, reference: nil) {
                    if first { first = false; waitingStarted.fulfill() }
                    try Task.checkCancellation()
                }
                XCTFail("A cancelled waiter must throw")
            } catch { XCTAssertTrue(error is CancellationError) }
            stopped.fulfill()
        }
        await fulfillment(of: [waitingStarted], timeout: 1)
        waiting.cancel()
        await fulfillment(of: [hit, stopped], timeout: 1)
        let result = await lookup.value
        XCTAssertTrue(result === cached)
        release.signal()
        _ = await preparing.value
        await waiting.value
    }

    func testValidatingInvocationHonoursTaskCancellation() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try FilmEngineInvocation(validating: TestStocks.negative,
                                              options: .init(), width: 8, height: 8)
                XCTFail("Cancelled invocation must throw before preparing any grain")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }
}
