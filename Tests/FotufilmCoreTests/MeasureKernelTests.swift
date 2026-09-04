#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

@_silgen_name("fotufilm_halide_metal_measure_tone_rows")
private func measure_tone_rows(
    _ input: UInt64, _ inputRows: UnsafePointer<Float>?,
    _ out: UnsafeMutablePointer<Float>?, _ gridWidth: Int32,
    _ width: Int32, _ rows: Int32, _ configuration: UnsafePointer<Float>?
) -> Int32

@_silgen_name("fotufilm_halide_metal_measure_flare_rows")
private func measure_flare_rows(
    _ input: UInt64, _ inputRows: UnsafePointer<Float>?,
    _ out: UnsafeMutablePointer<Float>?,
    _ width: Int32, _ rows: Int32, _ originY: Int32,
    _ configuration: UnsafePointer<Float>?, _ exposure: UnsafePointer<Float>?,
    _ film: UnsafePointer<Float>?, _ paper: UnsafePointer<Float>?,
    _ dimension: Int32, _ cacheID: UInt64, _ featureMask: Int32
) -> Int32

final class MeasureKernelTests: XCTestCase {
    private let width = 331
    private let height = 47
    private let bandRows = 17

    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
    }

    private func frame() -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        var state: UInt32 = 0x9E3779B9
        func noise() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) * (1.0 / 16_777_216.0)
        }
        for y in 0..<height {
            let tilt = Float(y) / Float(height - 1)
            for x in 0..<width {
                let stops = 6 * Float(x) / Float(width - 1) + 3 * (1 - tilt)
                // At or above 1 whatever the noise draws, so the peak channel never falls below
                // unit radiance and the two spectral recoveries stay comparable.
                let level = powf(2, stops) * (1 + 1.5 * noise())
                let index = (y * width + x) * 4
                pixels[index] = level * (0.6 + 0.8 * tilt)
                pixels[index + 1] = level
                pixels[index + 2] = level * (1.4 - 0.8 * tilt)
                pixels[index + 3] = 1
            }
        }
        return pixels
    }

    private func darkFrame() -> [Float] {
        var pixels = frame()
        for i in 0..<(width * height) {
            for c in 0..<3 { pixels[i * 4 + c] *= 0.004 }
        }
        return pixels
    }

    private func invocation() throws -> FilmEngineInvocation {
        var stock = TestStocks.negative
        stock.flare = 0.01
        var options = FotufilmEngine.Options()
        // Capture glare is opt-in now, and this test measures the flare kernel.
        options.flareScale = 1
        options.localTone = true
        options.highlights = 0.6
        options.shadows = -0.4
        options.exposureEV = 0.5
        options.whiteBalance = .init(kelvin: 5000, tint: 8)
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
        try XCTSkipUnless(invocation.localToneActive, "local tone must be live to be measured")
        try XCTSkipUnless(invocation.featureMask & FilmEngineFeature.flare != 0,
                          "flare must be live to be measured")
        return invocation
    }

    private func toneMeasurements(
        _ invocation: FilmEngineInvocation, _ pixels: [Float]
    ) throws -> (host: ToneBaseMeasurement, device: ToneBaseMeasurement) {
        var host = invocation.toneBaseMeasurement()
        var device = host
        let gridWidth = host.gridWidth
        var cells = [Float](repeating: 0, count: bandRows * gridWidth)
        try pixels.withUnsafeBufferPointer { frame in
            var row = 0
            while row < height {
                let upper = min(height, row + bandRows)
                let band = frame.baseAddress! + row * width * 4
                host.add(linearRGBA: band, rows: row..<upper)
                let status = cells.withUnsafeMutableBufferPointer { out in
                    invocation.configuration.withUnsafeBufferPointer { configuration in
                        measure_tone_rows(0, band, out.baseAddress, Int32(gridWidth),
                                          Int32(width), Int32(upper - row),
                                          configuration.baseAddress)
                    }
                }
                try XCTSkipUnless(status == 0, "no Metal device for the measure kernel")
                cells.withUnsafeBufferPointer {
                    device.add(cellRowSums: $0.baseAddress!, rows: row..<upper)
                }
                row = upper
            }
        }
        return (host, device)
    }

    func testDeviceToneMeasurementCountsTheSamePixels() throws {
        let invocation = try invocation()
        let (host, device) = try toneMeasurements(invocation, frame())
        XCTAssertEqual(device.counts, host.counts)
        XCTAssertEqual(host.counts.reduce(0, +), width * height)
    }

    func testDeviceToneMeasurementMatchesTheHostWalk() throws {
        let invocation = try invocation()
        let (host, device) = try toneMeasurements(invocation, frame())
        // Cell totals are in stops. The host accumulates in double; the kernel sums a cell's five
        // pixels in float32 and the host adds those partials on top, so the gap is a few
        // float32 ulps of a number around ten. Measured worst: 1.1e-7 relative. Held to 1e-5,
        // ninety times above it — and four orders below the 1/128-stop step a 16-bit deliverable
        // carries, so nothing that passes here is visible and nothing visible passes.
        for cell in 0..<host.logSum.count {
            let scale = max(1.0, abs(host.logSum[cell]))
            XCTAssertEqual(device.logSum[cell], host.logSum[cell], accuracy: 1e-5 * scale,
                           "tone cell \(cell)")
        }
        // And the thing the render actually reads: the solved grid. Measured worst 2.4e-7 absolute
        // — one float32 ulp of a coefficient near 1 — held to 1e-5, forty times above it.
        let (hostA, hostB) = host.solvedCoefficients()
        let (deviceA, deviceB) = device.solvedCoefficients()
        for i in 0..<hostA.count {
            XCTAssertEqual(deviceA[i], hostA[i], accuracy: 1e-5, "grid a[\(i)]")
            XCTAssertEqual(deviceB[i], hostB[i], accuracy: 1e-5, "grid b[\(i)]")
        }
    }

    private func flareRows(
        _ invocation: FilmEngineInvocation, _ pixels: [Float], exact: Bool
    ) throws -> (host: [SIMD3<Double>], device: [SIMD3<Double>]) {
        let mask = exact
            ? invocation.featureMask | FilmEngineFeature.exactMath
            : invocation.featureMask & ~FilmEngineFeature.exactMath
        var hostRows = [SIMD3<Double>](repeating: .zero, count: height)
        var deviceRows = [SIMD3<Double>](repeating: .zero, count: height)
        var kernelRows = [Float](repeating: 0, count: bandRows * 3)
        try pixels.withUnsafeBufferPointer { frame in
            try hostRows.withUnsafeMutableBufferPointer { sums in
                var row = 0
                while row < height {
                    let upper = min(height, row + bandRows)
                    let band = frame.baseAddress! + row * width * 4
                    let into = UnsafeMutableBufferPointer(
                        start: sums.baseAddress! + row, count: upper - row)
                    invocation.flareExposureRowSums(
                        linearRGBA: band, width: width, rows: upper - row,
                        startingAt: row, into: into)
                    let status = kernelRows.withUnsafeMutableBufferPointer { out in
                        invocation.configuration.withUnsafeBufferPointer { configuration in
                            invocation.withSpectralPointers { exposure, film, paper in
                                measure_flare_rows(
                                    0, band, out.baseAddress, Int32(width),
                                    Int32(upper - row), Int32(row),
                                    configuration.baseAddress, exposure, film, paper,
                                    Int32(invocation.spectral.exposure.dimension),
                                    invocation.spectralCacheID, mask)
                            }
                        }
                    }
                    try XCTSkipUnless(status == 0, "no Metal device for the measure kernel")
                    for local in 0..<(upper - row) {
                        deviceRows[row + local] = SIMD3(
                            Double(kernelRows[local * 3]),
                            Double(kernelRows[local * 3 + 1]),
                            Double(kernelRows[local * 3 + 2]))
                    }
                    row = upper
                }
            }
        }
        return (hostRows, deviceRows)
    }

    func testDeviceFlareMeasurementMatchesTheHostWalk() throws {
        var invocation = try invocation()
        let pixels = frame()
        // The glare pass runs after the tone solve and reads the solved grid through `originY`, so
        // pin a real grid first — against the identity default the row sums would agree for the
        // wrong reason.
        let (host, _) = try toneMeasurements(invocation, pixels)
        invocation.setToneBase(host)

        // The exact arm is the one the walk can referee: the walk has only libm, so the fast
        // transcendentals are a different function and are checked below by their own margin.
        let (hostRows, deviceRows) = try flareRows(invocation, pixels, exact: true)
        // A row sum is 331 exposures added in float32 against the host's double, so the gap is
        // float32 accumulation over 331 terms. Measured worst: 4.2e-7 relative on a row, 4.9e-8 on
        // the frame mean. Held to 1e-5 — twenty times above what was seen, and a hundred times
        // finer than the 0.1% a deliberate mutation of this reduction was measured to produce.
        for row in 0..<height {
            for lane in 0..<3 {
                let reference = hostRows[row][lane]
                XCTAssertEqual(deviceRows[row][lane], reference,
                               accuracy: 1e-5 * max(1e-3, abs(reference)),
                               "flare row \(row) lane \(lane)")
            }
        }
        // The number the render keeps is the frame mean, and it is what a wrong measurement moves.
        var hostTotal = SIMD3<Double>.zero, deviceTotal = SIMD3<Double>.zero
        for row in 0..<height { hostTotal += hostRows[row]; deviceTotal += deviceRows[row] }
        for lane in 0..<3 {
            let reference = hostTotal[lane] / Double(width * height)
            XCTAssertEqual(deviceTotal[lane] / Double(width * height), reference,
                           accuracy: 1e-5 * max(1e-3, abs(reference)), "flare mean lane \(lane)")
        }

        // The fast arm renders the video path: the same measurement with Halide's approximate log
        // and exp, which the tone stage's `metered -> stops -> gain` runs through. Measured worst:
        // 6.1e-7 relative, barely above the exact arm's, because the two transcendentals sit
        // either side of a smooth mask. Held to 1e-4.
        let (_, fastRows) = try flareRows(invocation, pixels, exact: false)
        for row in 0..<height {
            for lane in 0..<3 {
                let reference = hostRows[row][lane]
                XCTAssertEqual(fastRows[row][lane], reference,
                               accuracy: 1e-4 * max(1e-3, abs(reference)),
                               "fast flare row \(row) lane \(lane)")
            }
        }
    }

    func testDeviceFlareMeasurementIsBandingInvariant() throws {
        var invocation = try invocation()
        let pixels = darkFrame()
        let (host, _) = try toneMeasurements(invocation, pixels)
        invocation.setToneBase(host)

        let (_, banded) = try flareRows(invocation, pixels, exact: true)
        var whole = [Float](repeating: 0, count: height * 3)
        let status = pixels.withUnsafeBufferPointer { frame in
            whole.withUnsafeMutableBufferPointer { out in
                invocation.configuration.withUnsafeBufferPointer { configuration in
                    invocation.withSpectralPointers { exposure, film, paper in
                        measure_flare_rows(
                            0, frame.baseAddress!, out.baseAddress, Int32(width),
                            Int32(height), 0, configuration.baseAddress, exposure, film, paper,
                            Int32(invocation.spectral.exposure.dimension),
                            invocation.spectralCacheID,
                            invocation.featureMask | FilmEngineFeature.exactMath)
                    }
                }
            }
        }
        try XCTSkipUnless(status == 0, "no Metal device for the measure kernel")
        for row in 0..<height {
            for lane in 0..<3 {
                XCTAssertEqual(banded[row][lane], Double(whole[row * 3 + lane]),
                               "row \(row) lane \(lane) measured differently in a band")
            }
        }
    }
}
#endif
