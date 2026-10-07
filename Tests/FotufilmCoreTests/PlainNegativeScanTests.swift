import XCTest
@testable import FotufilmCore

final class PlainNegativeScanTests: XCTestCase {
    private let border = SIMD3<Float>(0.8, 0.45, 0.2)

    /// Film `density` over the base, as a scanner reads it.
    private func sample(_ density: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((0..<3).map { border[$0] * pow(10, -density[$0]) })
    }

    func testTheDensestEndPrintsAsDiffuseWhiteAndEveryStopFollowsTheNegativesContrast() {
        let reading = PlainNegativeScan(border: border, denseEnd: SIMD3(1.2, 1.1, 0.88))
        // Red and blue are balanced onto green at the densest end: a neutral highlight.
        XCTAssertEqual(reading.gains.x, 1.1 / 1.2, accuracy: 1e-6)
        XCTAssertEqual(reading.gains.z, 1.1 / 0.88, accuracy: 1e-6)
        let white = reading.light(of: sample(SIMD3(1.2, 1.1, 0.88)))
        for c in 0..<3 { XCTAssertEqual(white[c], PlainNegativeScan.highlight, accuracy: 1e-4) }
        // One stop down is gamma × log10(2) less density.
        let step = PlainNegativeScan.gamma * log10(Float(2))
        let grey = reading.light(of: sample(SIMD3(1.2 - step / reading.gains.x, 1.1 - step,
                                                   0.88 - step / reading.gains.z)))
        for c in 0..<3 { XCTAssertEqual(grey[c], PlainNegativeScan.highlight / 2, accuracy: 1e-4) }
    }

    func testAFlatFrameReadsUnbalancedAndBlankSamplesAreBlack() {
        let flat = PlainNegativeScan(border: border, denseEnd: nil)
        XCTAssertEqual(flat.gains, .one)
        XCTAssertEqual(flat.reference, PlainNegativeScan.defaultReference)
        XCTAssertEqual(PlainNegativeScan(border: border, denseEnd: SIMD3(0.01, 0.02, 0.01)), flat)
        // Gains stay within what a scanner channel can plausibly be off by.
        XCTAssertEqual(PlainNegativeScan(border: border, denseEnd: SIMD3(0.1, 1, 3)).gains,
                       SIMD3(2, 1, 0.5))
        XCTAssertEqual(flat.light(of: SIMD3(0, 0.2, 0.1)), .zero)
        XCTAssertEqual(flat.light(of: SIMD3(.nan, 0.2, 0.1)), .zero)
    }
}
