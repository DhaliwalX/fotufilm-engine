import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class ToneBaseTests: XCTestCase {

    func frame(width: Int, height: Int,
               stops: (_ x: Int, _ y: Int) -> Float) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = 0.18 * exp2(stops(x, y))
                let i = (y * width + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
                pixels[i + 3] = 1
            }
        }
        return pixels
    }

    func measurement(width: Int, height: Int,
                     pixels: [Float]) -> ToneBaseMeasurement {
        var measurement = ToneBaseMeasurement(
            frameWidth: width, frameHeight: height,
            balance: SIMD3(1, 1, 1), exposureGain: 1)
        pixels.withUnsafeBufferPointer {
            measurement.add(linearRGBA: $0.baseAddress!, rows: 0..<height)
        }
        return measurement
    }

    func testPackedDefaultIsTheIdentityGrid() {
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: FotufilmEngine.Options(),
            width: 640, height: 480)
        XCTAssertEqual(invocation.configuration[FilmEngineInvocation.frameSizeOffset], 640)
        XCTAssertEqual(invocation.configuration[FilmEngineInvocation.frameSizeOffset + 1], 480)
        XCTAssertEqual(invocation.configuration[FilmEngineInvocation.toneGridSizeOffset], 1)
        XCTAssertEqual(invocation.configuration[FilmEngineInvocation.toneGridSizeOffset + 1], 1)
        XCTAssertEqual(invocation.configuration[FilmEngineInvocation.toneGridAOffset], 1)
        XCTAssertEqual(invocation.configuration[FilmEngineInvocation.toneGridBOffset], 0)
    }

    func testGridFollowsAspect() {
        let square = ToneBaseMeasurement(frameWidth: 256, frameHeight: 256,
                                         balance: SIMD3(1, 1, 1), exposureGain: 1)
        XCTAssertEqual(square.gridWidth, 64)
        XCTAssertEqual(square.gridHeight, 64)
        let wide = ToneBaseMeasurement(frameWidth: 512, frameHeight: 256,
                                       balance: SIMD3(1, 1, 1), exposureGain: 1)
        XCTAssertEqual(wide.gridWidth, 64)
        XCTAssertEqual(wide.gridHeight, 32)
        let tiny = ToneBaseMeasurement(frameWidth: 8, frameHeight: 8,
                                       balance: SIMD3(1, 1, 1), exposureGain: 1)
        XCTAssertEqual(tiny.gridWidth, 8)
        XCTAssertEqual(tiny.gridHeight, 8)
    }

    func testFlatFieldSolvesToItsOwnLevel() {
        let width = 256, height = 256
        let level: Float = 3
        let pixels = frame(width: width, height: height) { _, _ in level }
        let (a, b) = measurement(width: width, height: height,
                                 pixels: pixels).solvedCoefficients()
        for i in 0..<(64 * 64) {
            XCTAssertEqual(a[i], 0, accuracy: 1e-4)
            XCTAssertEqual(b[i], level, accuracy: 0.01)
        }
    }

    func testRegionsAreSmoothedAndEdgesPreserved() {
        let width = 256, height = 256
        let pixels = frame(width: width, height: height) { _, y in
            y < height / 2 ? 0 : 6
        }
        let solved = measurement(width: width, height: height,
                                 pixels: pixels).solvedCoefficients()
        func at(_ cx: Int, _ cy: Int) -> (a: Float, b: Float) {
            (solved.a[cy * 64 + cx], solved.b[cy * 64 + cx])
        }
        XCTAssertLessThan(at(3, 3).a, 0.1)
        XCTAssertEqual(at(3, 3).b, 0, accuracy: 0.3)
        XCTAssertLessThan(at(60, 60).a, 0.1)
        XCTAssertEqual(at(60, 60).b, 6, accuracy: 0.3)
        XCTAssertGreaterThan(at(32, 32).a, 0.5)
    }

    func testBandsSolveIdenticallyToWholeFrame() {
        let width = 320, height = 240
        let pixels = frame(width: width, height: height) { x, y in
            2 * sin(Float(x) * 0.05) + Float(y) / 60
        }
        let whole = measurement(width: width, height: height, pixels: pixels)
        var banded = ToneBaseMeasurement(
            frameWidth: width, frameHeight: height,
            balance: SIMD3(1, 1, 1), exposureGain: 1)
        pixels.withUnsafeBufferPointer { buffer in
            var row = 0
            for band in [37, 101, 3, 99] {
                let upper = min(height, row + band)
                banded.add(linearRGBA: buffer.baseAddress! + row * width * 4,
                           rows: row..<upper)
                row = upper
            }
            banded.add(linearRGBA: buffer.baseAddress! + row * width * 4,
                       rows: row..<height)
        }
        let a = whole.solvedCoefficients(), b = banded.solvedCoefficients()
        XCTAssertEqual(a.a, b.a)
        XCTAssertEqual(a.b, b.b)
    }

#if canImport(Metal)
    func testTexturedRegionIsKeyedByItsRegionNotItsPixels() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 256, height = 256
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.halationScale = 0
        options.couplerScale = 0
        options.highlights = -1

        func stripeIsBright(_ x: Int) -> Bool { (x / 16) % 2 == 0 }
        let sky = frame(width: width, height: height) { x, y in
            y < height / 2 ? (stripeIsBright(x) ? 4.5 : 3.5) : 0
        }
        let developedSky = try XCTUnwrap(gpu.processLinearFloat(
            sky, width: width, height: height,
            stock: TestStocks.negative, options: options))
        func flat(_ stops: Float) throws -> [Float] {
            try XCTUnwrap(gpu.processLinearFloat(
                frame(width: width, height: height) { _, _ in stops },
                width: width, height: height,
                stock: TestStocks.negative, options: options))
        }
        let flatBright = try flat(4.5), flatDim = try flat(3.5)

        func skyMean(bright: Bool) -> Float {
            var sum: Float = 0; var count = 0
            for y in 8..<72 {
                for x in 0..<width where stripeIsBright(x) == bright
                    && x % 16 >= 6 && x % 16 < 10 {
                    sum += developedSky[(y * width + x) * 4 + 1]; count += 1
                }
            }
            return sum / Float(count)
        }
        func centre(_ pixels: [Float]) -> Float {
            pixels[(40 * width + width / 2) * 4 + 1]
        }
        XCTAssertGreaterThan(
            skyMean(bright: true), centre(flatBright) + 0.003,
            "bright texture was pulled as hard as a flat field at its level — keying is not regional")
        XCTAssertLessThan(
            skyMean(bright: false), centre(flatDim) - 0.003,
            "dim texture kept the flat-field shift — keying is not regional")
    }

    func testDisablingLocalToneRestoresPerPixelKeying() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 256, height = 256
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.halationScale = 0
        options.couplerScale = 0
        options.highlights = -1
        options.localTone = false

        XCTAssertFalse(FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height).localToneActive)

        func stripeIsBright(_ x: Int) -> Bool { (x / 16) % 2 == 0 }
        let sky = frame(width: width, height: height) { x, y in
            y < height / 2 ? (stripeIsBright(x) ? 4.5 : 3.5) : 0
        }
        let global = try XCTUnwrap(gpu.processLinearFloat(
            sky, width: width, height: height,
            stock: TestStocks.negative, options: options))
        func flat(_ stops: Float) throws -> Float {
            let developed = try XCTUnwrap(gpu.processLinearFloat(
                frame(width: width, height: height) { _, _ in stops },
                width: width, height: height,
                stock: TestStocks.negative, options: options))
            return developed[(40 * width + width / 2) * 4 + 1]
        }
        func skyMean(bright: Bool) -> Float {
            var sum: Float = 0; var count = 0
            for y in 8..<72 {
                for x in 0..<width where stripeIsBright(x) == bright
                    && x % 16 >= 6 && x % 16 < 10 {
                    sum += global[(y * width + x) * 4 + 1]; count += 1
                }
            }
            return sum / Float(count)
        }
        XCTAssertEqual(skyMean(bright: true), try flat(4.5), accuracy: 0.01)
        XCTAssertEqual(skyMean(bright: false), try flat(3.5), accuracy: 0.01)

        options.localTone = true
        let regional = try XCTUnwrap(gpu.processLinearFloat(
            sky, width: width, height: height,
            stock: TestStocks.negative, options: options))
        var worst: Float = 0
        for i in 0..<global.count { worst = max(worst, abs(global[i] - regional[i])) }
        XCTAssertGreaterThan(worst, 0.005, "the local-tone switch changed nothing")
    }

    func testStripedRenderMatchesWholeFrameWithToneControls() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 256, height = 2048
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let bright = abs(x - width / 2) < width / 12
                    && abs(y - height / 2) < height / 12
                let v: Float = bright ? 6 : 0.18 * Float(x) / Float(width) + 0.02
                let i = (y * width + x) * 4
                pixels[i] = v * 1.05; pixels[i + 1] = v; pixels[i + 2] = v * 0.92
            }
        }
        var options = FotufilmEngine.Options()
        options.format = .super8
        options.highlights = -0.7
        options.shadows = 0.5
        let whole = try XCTUnwrap(gpu.processLinearFloat(
            pixels, width: width, height: height, stock: TestStocks.negative,
            options: options, memoryBudget: 1 << 30))
        var strips = 0
        let tiled = try XCTUnwrap(gpu.processLinearFloat(
            pixels, width: width, height: height, stock: TestStocks.negative,
            options: options, memoryBudget: 21 << 20,
            progress: { if case .developing(_, let count) = $0 { strips = count } }))
        XCTAssertGreaterThan(strips, 1, "did not actually tile")
        var worst: Float = 0
        for i in 0..<whole.count { worst = max(worst, abs(whole[i] - tiled[i])) }
        XCTAssertLessThan(worst, 1.0 / 512, "seams between strips under local tone")
    }

    func testMetalMatchesCPUWithLocalToneControls() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.highlights = -0.8
        options.shadows = 0.6
        let size = 96
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let x = i % size, y = i / size
            let bright = abs(x - size / 2) < 10 && abs(y - size / 2) < 10
            let v: UInt8 = bright ? 250 : 40
            pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = 255
        }
        let cpu = FotufilmEngine(stock: TestStocks.negative, options: options)
            .processSRGB8(pixels, width: size, height: size)
        let gpuOut = try XCTUnwrap(gpu.processSRGB8(
            pixels, width: size, height: size,
            stock: TestStocks.negative, options: options))
        var maxDiff = 0, sumDiff = 0
        for i in 0..<(size * size) {
            for c in 0..<3 {
                let d = abs(Int(cpu[i * 4 + c]) - Int(gpuOut[i * 4 + c]))
                maxDiff = max(maxDiff, d)
                sumDiff += d
            }
        }
        let meanDiff = Double(sumDiff) / Double(size * size * 3)
        XCTAssertLessThan(meanDiff, 1.0,
                          "schedules drift under local tone (mean |diff| \(meanDiff))")
        XCTAssertLessThanOrEqual(maxDiff, 6, "worst-case divergence \(maxDiff)/255")
    }
#endif
}
