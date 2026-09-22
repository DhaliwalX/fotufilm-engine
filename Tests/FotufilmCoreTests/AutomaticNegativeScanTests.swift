import XCTest
@testable import FotufilmCore

final class AutomaticNegativeScanTests: XCTestCase {
    func ramp() -> ImageBuffer {
        let n = 512
        let planes = [Float(0.7), 0.35, 0.15].map { base in
            (0..<n).map { i in base * (0.02 + 0.98 * Float(i) / Float(n-1)) }
        }
        return ImageBuffer(width: 256, height: 2, planes: planes)
    }
    func testWholeFrameStatisticsIgnoreSparseDustAndRejectMalformedInput() throws {
        let image = ramp()
        let plan = try AutomaticNegativeScan(preview: image)
        var dusty = image
        for c in 0..<3 { dusty.planes[c][100] = 1000; dusty.planes[c][101] = 0 }
        let actual = try AutomaticNegativeScan(preview: dusty)
        XCTAssertFalse(plan.weak)
        for c in 0..<6 { XCTAssertEqual(actual.parameters[c], plan.parameters[c], accuracy: 0.004) }
        XCTAssertThrowsError(try AutomaticNegativeScan(preview: ImageBuffer(width: 1024, height: 1)))
        XCTAssertThrowsError(try AutomaticNegativeScan(preview: ImageBuffer(width: 8, height: 8)))
    }
    func testMonotonicDetailAndMetalAgreement() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide unavailable") }
        let input = ramp(), plan = try AutomaticNegativeScan(preview: ramp())
        let cpu = try plan.convert(input, useMetal: false)
        let gpu = try plan.convert(input)
        for c in 0..<3 {
            for i in 0..<input.pixelCount {
                XCTAssertTrue(cpu.planes[c][i].isFinite)
                XCTAssertEqual(cpu.planes[c][i], gpu.planes[c][i], accuracy: 2e-5)
                if i > 0 { XCTAssertGreaterThanOrEqual(cpu.planes[c][i-1], cpu.planes[c][i]) }
            }
        }
    }
    func testFlatImageRemainsFlatAndInvalidPixelsAreBlack() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide unavailable") }
        let image = ImageBuffer(width: 8, height: 8, planes: [[Float]](repeating: [Float](repeating: 0.3, count: 64), count: 3))
        let plan = try AutomaticNegativeScan(preview: image)
        XCTAssertTrue(plan.weak)
        var invalid = image
        invalid.planes[0][0] = .nan
        for c in 0..<3 { invalid.planes[c][1] = 0 }
        let out = try plan.convert(invalid, useMetal: false)
        for c in 0..<3 {
            XCTAssertEqual(out.planes[c][0], 0); XCTAssertEqual(out.planes[c][1], 0)
            XCTAssertEqual(out.planes[c][2], 0.214041, accuracy: 1e-5)
        }
    }
    func testWideGamutAndClippedChannelsDoNotBecomeBlackPixels() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide unavailable") }
        let plan = try AutomaticNegativeScan(preview: ramp())
        var input = ImageBuffer(width: 8, height: 2, planes: [[Float]](repeating: [Float](repeating: 0.2, count: 16), count: 3))
        input.planes[2][0] = -0.008 // A valid saturated P3 colour in extended sRGB.
        input.planes[2][1] = 0
        input.planes[2][2] = 0.000001
        input.planes[0][3] = .nan
        input.planes[1][4] = .infinity
        for c in 0..<3 { input.planes[c][5] = 0; input.planes[c][6] = -0.01 }
        let cpu = try plan.convert(input, useMetal: false)
        let metal = try plan.convert(input, useMetal: true)
        for c in 0..<3 { for i in 0..<input.pixelCount {
            XCTAssertTrue(cpu.planes[c][i].isFinite)
            XCTAssertEqual(cpu.planes[c][i], metal.planes[c][i], accuracy: 2e-5)
        } }
        for i in 0...2 {
            XCTAssertGreaterThan(cpu.planes.map { $0[i] }.reduce(0, +), 0.1)
        }
        for c in 0..<3 {
            // Crossing the sRGB gamut boundary must not introduce black speckles.
            XCTAssertEqual(cpu.planes[c][0], cpu.planes[c][1], accuracy: 1e-6)
            XCTAssertEqual(cpu.planes[c][1], cpu.planes[c][2], accuracy: 1e-4)
            for i in 3...6 { XCTAssertEqual(cpu.planes[c][i], 0) }
        }
    }
    func testAnalysisIncludesWideGamutPixelsAndMatchesChannelClamping() throws {
        var image = ramp()
        for i in 0..<image.pixelCount { image.planes[2][i] -= 0.07 }
        var clamped = image
        for c in 0..<3 { for i in 0..<image.pixelCount { clamped.planes[c][i] = max(0, image.planes[c][i]) } }
        let actual = try AutomaticNegativeScan(preview: image)
        let expected = try AutomaticNegativeScan(preview: clamped)
        XCTAssertEqual(actual.sampleCount, 412)
        XCTAssertEqual(actual.parameters, expected.parameters)
        XCTAssertEqual(actual.parameters[2], 0)
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide unavailable") }
        let cpu = try actual.convert(image, useMetal: false)
        let metal = try actual.convert(image, useMetal: true)
        for c in 0..<3 { for i in 0..<image.pixelCount {
            XCTAssertTrue(cpu.planes[c][i].isFinite)
            XCTAssertEqual(cpu.planes[c][i], metal.planes[c][i], accuracy: 2e-5)
        } }
    }

}
