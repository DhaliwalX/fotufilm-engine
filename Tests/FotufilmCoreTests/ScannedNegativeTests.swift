import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class ScannedNegativeTests: XCTestCase {
    private let identity: [SIMD3<Float>] = [.init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1)]

    private func calibration(reference: ScanDensityReference = .clearLight,
                             offset: SIMD3<Float> = .zero) throws -> ScanDensityCalibration {
        try ScanDensityCalibration(reference: reference, rows: identity, offset: offset)
    }

    func testKnownTransmissionAndDarkSubtraction() throws {
        let converter = try ScannedNegativeConverter(dark: .init(0.1, 0.2, 0.3),
                                                     light: .init(1.1, 2.2, 3.3),
                                                     reference: .clearLight)
        let scan = ImageBuffer(width: 3, height: 1, planes: [
            [1.1, 0.2, 0.11], [2.2, 0.4, 0.22], [3.3, 0.6, 0.33],
        ])
        let densities = try converter.scannerDensity(linearScan: scan)
        for plane in densities.planes {
            for index in 0..<3 { XCTAssertEqual(plane[index], Float(index), accuracy: 2e-6) }
        }
        XCTAssertEqual(scan.planes[0][0], 1.1, "conversion must not mutate the input")
    }

    func testFilmBaseReferenceRestoresModelBaseAndAllowsThinnerSamples() throws {
        let converter = try ScannedNegativeConverter(dark: .zero, light: .init(0.8, 0.5, 0.2),
                                                     reference: .filmBase)
        let scan = ImageBuffer(width: 2, height: 1, planes: [[0.8, 1], [0.5, 0.5], [0.2, 0.2]])
        let base = SIMD3<Float>(0.2, 0.4, 0.6)
        let density = try converter.negativeDensity(linearScan: scan,
            calibration: calibration(reference: .filmBase, offset: base))
        for channel in 0..<3 { XCTAssertEqual(density.planes[channel][0], base[channel]) }
        XCTAssertEqual(density.planes[0][1], 0.2 - log10(1.25), accuracy: 1e-6)
        XCTAssertThrowsError(try converter.negativeDensity(linearScan: scan,
                                                           calibration: calibration())) {
            XCTAssertEqual($0 as? ScannedNegativeError, .referenceMismatch)
        }
    }

    func testCalibrationMixesChannelsInFilmRecordOrder() throws {
        let converter = try ScannedNegativeConverter(dark: .zero, light: .one, reference: .clearLight)
        let mapping = try ScanDensityCalibration(reference: .clearLight,
            rows: [.init(1, 0.5, 0), .init(0, 1, -0.25), .init(0.2, 0, 1)],
            offset: .init(0.1, 0.2, 0.3))
        let scan = ImageBuffer(width: 1, height: 1, interleavedRGB: [0.1, 0.01, 0.001])
        let result = try converter.negativeDensity(linearScan: scan, calibration: mapping)
        for (actual, expected) in zip(result.interleavedRGB(), [Float(2.1), 1.45, 3.5]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-6)
        }
    }

    func testRejectsInvalidReferencesCalibrationAndPixels() throws {
        for value in [Float(0), -1, .infinity, .nan] {
            XCTAssertThrowsError(try ScannedNegativeConverter(dark: .zero,
                light: .init(1, value, 1), reference: .clearLight))
        }
        XCTAssertThrowsError(try ScannedNegativeConverter(dark: .init(.nan, 0, 0),
            light: .one, reference: .clearLight))
        XCTAssertThrowsError(try ScanDensityCalibration(reference: .clearLight, rows: [], offset: .zero))
        XCTAssertThrowsError(try ScanDensityCalibration(reference: .clearLight,
            rows: identity, offset: .init(.infinity, 0, 0)))
        XCTAssertThrowsError(try ScanDensityCalibration(reference: .clearLight,
            rows: [.init(.nan, 0, 0), identity[1], identity[2]], offset: .zero))
        let converter = try ScannedNegativeConverter(dark: .zero, light: .one, reference: .clearLight)
        for value in [Float(0), -1, .infinity, .nan] {
            let scan = ImageBuffer(width: 1, height: 1, interleavedRGB: [1, value, 1])
            XCTAssertThrowsError(try converter.scannerDensity(linearScan: scan)) {
                XCTAssertEqual($0 as? ScannedNegativeError, .invalidSample(channel: 1, pixel: 0))
            }
        }
        var malformed = ImageBuffer(width: 1, height: 1)
        malformed.planes = [[1]]
        XCTAssertThrowsError(try converter.scannerDensity(linearScan: malformed))
        XCTAssertThrowsError(try converter.scannerDensity(linearScan: ImageBuffer(width: 0, height: 0)))
    }

    func testDensityRangeIsValidatedWithoutClipping() throws {
        let converter = try ScannedNegativeConverter(dark: .zero, light: .one, reference: .clearLight)
        let scan = ImageBuffer(width: 3, height: 1, planes: Array(repeating: [1, 1e-4, 1e-8], count: 3))
        let density = try converter.negativeDensity(linearScan: scan, calibration: calibration())
        XCTAssertEqual(density.planes[0], [0, 4, 8])
        for value in [Float(1e-9), 10] {
            XCTAssertThrowsError(try converter.negativeDensity(
                linearScan: ImageBuffer(width: 1, height: 1, fill: value), calibration: calibration())) {
                XCTAssertEqual($0 as? ScannedNegativeError, .densityOutOfRange(channel: 0, pixel: 0))
            }
        }
    }

    func testPositiveEntryRejectsNegativeViewingAndReversal() throws {
        let converter = try ScannedNegativeConverter(dark: .zero, light: .one, reference: .clearLight)
        let scan = ImageBuffer(width: 1, height: 1, fill: 0.5)
        var negative = FotufilmEngine.Options()
        negative.paper = .negative
        var preview = FotufilmEngine.Options()
        preview.negativeViewing = .scanner
        for engine in [FotufilmEngine(stock: TestStocks.negative, options: negative),
                       FotufilmEngine(stock: TestStocks.negative, options: preview),
                       FotufilmEngine(stock: TestStocks.reversal)] {
            XCTAssertThrowsError(try engine.printScannedNegative(linearScan: scan,
                converter: converter, calibration: calibration())) {
                XCTAssertEqual($0 as? ScannedNegativeError, .positiveOutputRequired)
            }
        }
    }

    /// Synthetic ideal channels isolate scan recovery from scanner profiling. This is not a
    /// calibration of a real scanner. The textured ramp exercises preservation of existing grain.
    func testSyntheticScanRoundTripAndPrintBypassesDevelopment() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        let size = 32
        var scene = ImageBuffer(width: size, height: size)
        for c in 0..<3 {
            for i in 0..<scene.pixelCount {
                scene.planes[c][i] = 0.01 + Float((i + c * 9) % size) / Float(size)
            }
        }
        let engine = FotufilmEngine(stock: TestStocks.negative)
        let original = engine.developNegative(linearRGB: scene)
        var scan = original
        for c in 0..<3 {
            for i in 0..<scan.pixelCount { scan.planes[c][i] = pow(10, -original.planes[c][i]) }
        }
        let converter = try ScannedNegativeConverter(dark: .zero, light: .one, reference: .clearLight)
        let mapping = try calibration()
        let recovered = try converter.negativeDensity(linearScan: scan, calibration: mapping)
        for c in 0..<3 {
            for i in 0..<scan.pixelCount {
                XCTAssertEqual(recovered.planes[c][i], original.planes[c][i], accuracy: 5e-7)
            }
        }
        let expected = engine.printPositive(negativeDensity: original)
        var changed = engine
        changed.options.stage = .negative
        changed.options.halationScale = 2
        changed.options.grainScale = 3
        let positive = try changed.printScannedNegative(linearScan: scan, converter: converter,
                                                        calibration: mapping)
        for c in 0..<3 {
            for i in 0..<scan.pixelCount {
                XCTAssertEqual(positive.planes[c][i], expected.planes[c][i], accuracy: 2e-5)
            }
        }
        #if canImport(Metal)
        if let gpu = HalideMetalFilmRenderer.shared {
            var rgba = [Float](repeating: 1, count: scan.pixelCount * 4)
            for c in 0..<3 {
                for i in 0..<scan.pixelCount { rgba[i * 4 + c] = recovered.planes[c][i] }
            }
            var options = engine.options
            options.stage = .print
            let metal = try XCTUnwrap(gpu.processLinearFloat(rgba, width: size, height: size,
                stock: engine.stock, options: options))
            for c in 0..<3 {
                for i in 0..<scan.pixelCount {
                    // The Metal float delivery endpoint floors negative display RGB to zero;
                    // the CPU print seam returns the signed LUT output before delivery.
                    XCTAssertEqual(metal[i * 4 + c], max(positive.planes[c][i], 0), accuracy: 2e-4)
                }
            }
        }
        #endif
    }
}
