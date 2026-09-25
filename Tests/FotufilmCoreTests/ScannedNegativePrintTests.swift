import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class ScannedNegativePrintTests: XCTestCase {
    private let border = SIMD3<Float>(0.82, 0.41, 0.19)

    /// A scan of film at the border and denser, plus holder light brighter than any film.
    private func scan(width: Int, height: Int) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            let thin = Float(x) / Float(width - 1), row = Float(y) / Float(height - 1)
            for c in 0..<3 {
                image.planes[c][i] = border[c] * pow(10, -(0.05 + 1.6 * thin * (0.6 + 0.4 * row)
                    + 0.05 * Float(c)))
            }
            if x == width - 1 && y.isMultiple(of: 3) {
                for c in 0..<3 { image.planes[c][i] = 50 }
            }
        } }
        return image
    }

    func testSampleDensityIsTheBorderConversion() throws {
        let calibration = try ApproximateNegativeScan(stock: TestStocks.negative, border: border)
        let image = scan(width: 17, height: 9)
        let converted = try calibration.convert(image)
        for i in 0..<image.pixelCount {
            let sample = SIMD3(image.planes[0][i], image.planes[1][i], image.planes[2][i])
            let density = calibration.density(of: sample)
            XCTAssertEqual(density == nil, converted.invalid[i])
            guard let density else { continue }
            for c in 0..<3 {
                XCTAssertEqual(density[c], converted.density.planes[c][i], accuracy: 1e-5)
            }
        }
        XCTAssertTrue(converted.invalid.contains(true), "holder light is outside the film")
    }

    /// A scanner whose red channel reads only 80% of the cyan dye's density: the balance restores
    /// the red record's contrast and places the highlights where the frame's brightest exposure
    /// sits over mid-grey.
    func testBalanceRestoresAWeakChannelAndFindsTheHighlights() throws {
        let stock = TestStocks.negative
        let width = 200, height = 40
        let highest: Float = 1.2, lowest: Float = -2
        var scan = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let logExposure = lowest + (highest - lowest) * Float(x) / Float(width - 1)
            for c in 0..<3 {
                let curve = stock.curves[c]
                let above = curve.density(logExposure: logExposure) - curve.dMin
                scan.planes[c][y * width + x] = border[c] * pow(10, -(c == 0 ? 0.8 : 1) * above)
            }
        } }
        let balance = ApproximateNegativeScan.balance(stock: stock, border: border, preview: scan)
        XCTAssertEqual(balance.gains.x, 1.25, accuracy: 0.02)
        XCTAssertEqual(balance.gains.y, 1)
        XCTAssertEqual(balance.gains.z, 1, accuracy: 0.02)
        let stops = try XCTUnwrap(balance.highlightStops)
        // The 99.5th percentile of the central columns, in stops over mid-grey.
        let expected = (lowest + (highest - lowest) * 0.895) / log10(2)
        XCTAssertEqual(stops, expected, accuracy: 0.1)

        let calibration = try ApproximateNegativeScan(stock: stock, border: border,
                                                      gains: balance.gains)
        let sample = SIMD3((0..<3).map { scan.planes[$0][150] })
        let density = try XCTUnwrap(calibration.density(of: sample))
        let exposure = lowest + (highest - lowest) * 150 / Float(width - 1)
        XCTAssertEqual(density.x, stock.curves[0].density(logExposure: exposure), accuracy: 0.02)
    }

    /// Banded printing must match the one-shot print stage on the same densities, and paint the
    /// holder black.
    func testBandedScanPrintMatchesThePrintStage() throws {
        #if canImport(Metal)
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let width = 96, height = 64
        let image = scan(width: width, height: height)
        let stock = TestStocks.negative
        let calibration = try ApproximateNegativeScan(stock: stock, border: border)
        let converted = try calibration.convert(image)
        var options = FotufilmEngine.Options()
        options.paper = .screen
        options.stage = .print
        var film = stock
        film.layeredTransport = nil
        var densities = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<image.pixelCount { for c in 0..<3 {
            densities[i * 4 + c] = converted.density.planes[c][i]
        } }
        let expected = try XCTUnwrap(gpu.processLinearFloat(
            densities, width: width, height: height, stock: film, options: options))

        var printed = [Float](repeating: -1, count: width * height * 4)
        let ok = gpu.printScan(
            width: width, height: height, stock: stock, options: options,
            calibration: calibration,
            readScan: { rows, into in
                for row in rows { for x in 0..<width {
                    let i = row * width + x, o = ((row - rows.lowerBound) * width + x) * 4
                    for c in 0..<3 { into[o + c] = image.planes[c][i] }
                    into[o + 3] = 1
                } }
            },
            writeRows: { rows, from in
                for (offset, value) in from.enumerated() {
                    printed[rows.lowerBound * width * 4 + offset] = value
                }
            })
        XCTAssertTrue(ok)
        for i in 0..<image.pixelCount { for c in 0..<3 {
            if converted.invalid[i] {
                XCTAssertEqual(printed[i * 4 + c], 0, "holder pixel \(i)")
            } else {
                XCTAssertEqual(printed[i * 4 + c], expected[i * 4 + c], accuracy: 2e-4,
                               "pixel \(i) channel \(c)")
            }
        } }
        #else
        throw XCTSkip("Metal required")
        #endif
    }

    /// Less yellow filtration puts more blue light through the negative, so the print carries
    /// more yellow dye: warmer.
    func testLessYellowFiltrationPrintsWarmer() throws {
        #if canImport(Metal)
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let stock = TestStocks.negative
        let calibration = try ApproximateNegativeScan(stock: stock, border: border)
        let width = 8, height = 8
        let grey = SIMD3<Float>(repeating: 1) * border * pow(10, -0.7)
        func print(yellow: Float) throws -> SIMD3<Float> {
            var options = FotufilmEngine.Options()
            options.paper = .crystalArchive
            options.printer = PrinterProfile(yellow: yellow)
            var out = SIMD3<Float>.zero
            XCTAssertTrue(gpu.printScan(
                width: width, height: height, stock: stock, options: options,
                calibration: calibration,
                readScan: { rows, into in
                    for p in 0..<rows.count * width {
                        into[p * 4] = grey.x
                        into[p * 4 + 1] = grey.y
                        into[p * 4 + 2] = grey.z
                        into[p * 4 + 3] = 1
                    }
                },
                writeRows: { _, from in out = SIMD3(from[0], from[1], from[2]) }))
            return out
        }
        let reference = try print(yellow: PrinterProfile.simulatedTungsten.yellow)
        let warmer = try print(yellow: PrinterProfile.simulatedTungsten.yellow - 0.3)
        XCTAssertGreaterThan(warmer.x / warmer.z, reference.x / reference.z)
        #else
        throw XCTSkip("Metal required")
        #endif
    }
}
