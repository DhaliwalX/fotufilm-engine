import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebNegativeScanRequestTests: XCTestCase {
    private func input(stock id: String = "gold200", border: [Float] = [0.4, 0.6, 0.2],
                       width: Int = 32, height: Int = 24) throws -> Data {
        let stock = try XCTUnwrap(FilmStock.presetDefinitions[id])
        return try JSONSerialization.data(withJSONObject: [
            "kind": "negative-scan", "stock": JSONSerialization.jsonObject(with: JSONEncoder().encode(stock)),
            "border": border, "width": width, "height": height,
        ])
    }

    func testPrintProfileMatchesNativeImportAndExportsReferenceWhenRequested() throws {
        for id in ["gold200", "hp5plus400"] {
            let width = 32, height = 24
            let stock = try XCTUnwrap(FilmStock.presetDefinitions[id]).validated().stock
            let request = try input(stock: id)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: WebRenderRequest.prepare(request)) as? [String: Any])
            let profile = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(result["profile"] as? String)))
            var options = FotufilmEngine.Options()
            options.paper = .screen
            options.stage = .print
            XCTAssertEqual(profile, try WebFilmProfile.prepare(stock: stock, options: options, width: width, height: height))
            let invocation = try FilmEngineInvocation(validating: stock, options: options, width: width, height: height)
            XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.densityIn, 0)
            XCTAssertEqual(invocation.featureMask & (FilmEngineFeature.grain | FilmEngineFeature.halation), 0)

            // Synthetic transmission patches exercise film-base removal, record order,
            // monochrome capture and invalid holder pixels without shipping a photograph.
            let border = SIMD3<Float>(0.4, 0.6, 0.2)
            var scan = ImageBuffer(width: width, height: height)
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = y * width + x
                    for c in 0..<3 {
                        let density = Float((x + y * (c + 1)) % 32) / 12
                        scan.planes[c][pixel] = border[c] * pow(10, -density)
                    }
                }
            }
            scan.planes[0][0] = 0
            let converted = try ApproximateNegativeScan(stock: stock, border: border).convert(scan)
            var nativeOptions = FotufilmEngine.Options()
            nativeOptions.paper = .screen
            let positive = try FotufilmEngine(stock: stock, options: nativeOptions)
                .printPositiveChecked(negativeDensity: converted.density)
            XCTAssertTrue(positive.planes.flatMap { $0 }.allSatisfy(\.isFinite))
            if let path = ProcessInfo.processInfo.environment["FOTUFILM_SCAN_REFERENCE_DIRECTORY"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let fixture: [String: Any] = [
                    "request": try JSONSerialization.jsonObject(with: request), "result": result,
                    "scan": scan.interleavedRGB(), "density": converted.density.interleavedRGB(),
                    "positive": positive.interleavedRGB(), "invalid": converted.invalid,
                ]
                try JSONSerialization.data(withJSONObject: fixture).write(to: directory.appendingPathComponent("\(id).json"))
            }
        }
    }

    func testRejectsMissingBorderInvalidDimensionsAndReversal() throws {
        for border: [Float] in [[], [1, 1], [1, 0, 1], [-1, 1, 1]] {
            XCTAssertThrowsError(try WebRenderRequest.prepare(input(border: border)))
        }
        for size in [(0, 24), (32, -1), (120_001, 1), (20_000, 20_000)] {
            XCTAssertThrowsError(try WebRenderRequest.prepare(input(width: size.0, height: size.1)))
        }
        let reversal = try XCTUnwrap(FilmStock.presetDefinitions.first { $0.value.stock.isReversal }?.key)
        XCTAssertThrowsError(try WebRenderRequest.prepare(input(stock: reversal)))
    }
}
