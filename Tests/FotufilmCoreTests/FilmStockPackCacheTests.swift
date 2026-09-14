import XCTest
@testable import FotufilmCore

final class FilmStockPackCacheTests: XCTestCase {
    private enum Failure: Error { case old, current }

    private final class Loader: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        let oldFails: Bool
        let currentFails: Bool

        init(oldFails: Bool = false, currentFails: Bool = false) {
            self.oldFails = oldFails; self.currentFails = currentFails
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        func load() throws -> FilmStockPack {
            lock.lock()
            calls += 1
            let call = calls
            lock.unlock()
            if call == 1 {
                started.signal()
                guard resume.wait(timeout: .now() + 10) == .success else {
                    XCTFail("test did not release the old load")
                    throw Failure.old
                }
                if oldFails { throw Failure.old }
                return FilmStockPack(warnings: ["old"])
            }
            if currentFails { throw Failure.current }
            return FilmStockPack(warnings: ["current"])
        }
    }

    func testReloadSupersedesInflightSuccessAndFailure() {
        for oldFails in [false, true] {
            for currentFails in [false, true] {
                let loader = Loader(oldFails: oldFails, currentFails: currentFails)
                let cache = FilmStockPackCache(loader: loader.load)
                let completed = DispatchGroup()
                completed.enter()
                DispatchQueue.global().async {
                    XCTAssertEqual(cache.shared.warnings, currentFails ? [] : ["current"])
                    completed.leave()
                }
                XCTAssertEqual(loader.started.wait(timeout: .now() + 10), .success)
                XCTAssertEqual(cache.reload().warnings, currentFails ? [] : ["current"])
                loader.resume.signal()
                XCTAssertEqual(completed.wait(timeout: .now() + 10), .success)
                XCTAssertEqual(cache.shared.warnings, currentFails ? [] : ["current"])
                XCTAssertEqual(cache.generation, 1)
                XCTAssertEqual(loader.count, 2)
                if currentFails {
                    guard case Failure.current? = cache.loadError else {
                        return XCTFail("stale completion replaced the current load error")
                    }
                } else {
                    XCTAssertNil(cache.loadError)
                }
            }
        }
    }

    func testConcurrentColdReadersShareOneLoad() {
        let loader = Loader()
        let cache = FilmStockPackCache(loader: loader.load)
        let completed = DispatchGroup()
        for _ in 0..<32 {
            completed.enter()
            DispatchQueue.global().async {
                XCTAssertEqual(cache.shared.warnings, ["old"])
                completed.leave()
            }
        }
        XCTAssertEqual(loader.started.wait(timeout: .now() + 10), .success)
        loader.resume.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(loader.count, 1)
        XCTAssertEqual(cache.generation, 0)
    }
}
