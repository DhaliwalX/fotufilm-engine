import XCTest
@testable import FotufilmEditModel

final class LatestRequestGateTests: XCTestCase {
    func testRapidRequestsAcceptOnlyNewestResult() {
        var gate = LatestRequestGate()

        let firstFilm = gate.issue()
        let secondFilm = gate.issue()
        let thirdFilm = gate.issue()

        XCTAssertFalse(gate.accepts(firstFilm))
        XCTAssertFalse(gate.accepts(secondFilm))
        XCTAssertTrue(gate.accepts(thirdFilm))
    }

    func testInvalidationRejectsOutstandingResult() {
        var gate = LatestRequestGate()
        let request = gate.issue()

        gate.invalidate()

        XCTAssertFalse(gate.accepts(request))
    }
}
