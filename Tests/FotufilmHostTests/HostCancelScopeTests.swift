import XCTest
@testable import FotufilmHost

/// An export the host runs in the background keeps going through the editor's cancels, and stops
/// at its own.
final class HostCancelScopeTests: XCTestCase {
    func testABackgroundCallOutlivesTheEditorsCancels() throws {
        let engine: HostEngine
        do { engine = try HostEngine() } catch { throw XCTSkip("\(error)") }
        let develop = engine.continuation()
        let export = HostEngine.$scope.withValue(.background) { engine.continuation() }

        engine.cancel()
        XCTAssertFalse(develop())
        XCTAssertTrue(export())

        // A scope's check holds from any thread, as the batch export's workers ask it.
        let elsewhere = DispatchQueue.global().sync { export() }
        XCTAssertTrue(elsewhere)

        _ = try engine.service.call("cancelBackground", params: Data("{}".utf8), payload: nil)
        XCTAssertFalse(export())
        XCTAssertTrue(engine.continuation()())
    }
}
