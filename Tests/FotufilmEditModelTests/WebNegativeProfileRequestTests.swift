import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebNegativeProfileRequestTests: XCTestCase {
    private func definition(_ id: String) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(FilmStock.presetDefinitions[id])))
    }

    private func profile(stock id: String = "gold200", border: [Float] = [0.4, 0.6, 0.2],
                         denseEnd: [Float]? = [1.1, 1.0, 0.9], width: Int = 32, height: Int = 24,
                         medium: String = "screen", light: [String: Double]? = nil) throws -> Data {
        var negative: [String: Any] = ["border": border]
        if let denseEnd { negative["denseEnd"] = denseEnd }
        if let light { negative["light"] = light }
        return try JSONSerialization.data(withJSONObject: [
            "stock": try definition(id), "width": width, "height": height, "medium": medium,
            "controls": [String: Any](), "negative": negative,
        ])
    }

    private func printed(_ id: String) throws -> FilmStock {
        var stock = try NegativeScanPrint.film(XCTUnwrap(FilmStock.presetDefinitions[id]).validated().stock)
        stock.layeredTransport = nil
        return stock
    }

    private func edit(_ id: String, medium: String, light: [String: Double]) throws -> WebNativeEdit {
        try JSONDecoder().decode(WebNativeEdit.self, from: JSONSerialization.data(withJSONObject: [
            "edit": ["stock": id, "params": light],
            "profileRequest": ["medium": medium, "controls": [String: Any]()],
        ]))
    }

    func testPrintProfileMatchesTheDesktopAndExportsAReferenceWhenRequested() throws {
        for id in ["gold200", "hp5plus400"] {
            let width = 32, height = 24
            let stock = try printed(id)
            let border = SIMD3<Float>(0.4, 0.6, 0.2), dense = SIMD3<Float>(1.1, 1.0, 0.9)
            let native = try NegativeScanPrint.Reading(
                stock: stock, border: border,
                balance: ApproximateNegativeScan.balance(stock: stock, denseEnd: dense))

            // The film's print profile, as the desktop host prints the same reading, with light
            // controls that reach the scan and the print's finish.
            let light: [String: Double] = ["ev": 0.5, "temperature": 5000]
            let request = try profile(stock: id, light: light)
            let pack = try WebRenderRequest.prepare(request)
            var options = native.printing(try edit(id, medium: "screen", light: light).options(for: stock),
                                          stock: stock)
            XCTAssertEqual(options.scanReading, native.calibration)
            XCTAssertEqual(pack, try WebFilmProfile.prepare(stock: stock, options: options, width: width, height: height))
            // The rest of the finish the renderer writes at render time.
            let finish: [String: Float] = ["highlights": -0.5, "shadows": 0.4, "saturation": 1.25,
                                           "vibrance": 0.2]
            options.printFinish.highlights = finish["highlights"]!
            options.printFinish.shadows = finish["shadows"]!
            options.printFinish.saturation = finish["saturation"]!
            options.printFinish.vibrance = finish["vibrance"]!
            let invocation = try FilmEngineInvocation(validating: stock, options: options, width: width, height: height)
            XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.densityIn, 0)
            XCTAssertEqual(invocation.featureMask & (FilmEngineFeature.grain | FilmEngineFeature.halation), 0)

            // Synthetic transmission patches exercise film-base removal, record order,
            // monochrome capture and invalid holder pixels without shipping a photograph.
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
            // The kernels read the scan as `ApproximateNegativeScan.density(of:)` does, and print
            // what it cannot place black.
            let positive = try FotufilmEngine(stock: stock, options: options)
                .printPositiveChecked(negativeDensity: scan)
            let converted = try native.calibration.convert(scan)
            var densities = options
            densities.scanReading = nil
            let reference = try FotufilmEngine(stock: stock, options: densities)
                .printPositiveChecked(negativeDensity: converted.density)
            for i in 0..<scan.pixelCount { for c in 0..<3 {
                XCTAssertEqual(positive.planes[c][i], converted.invalid[i] ? 0 : reference.planes[c][i],
                               accuracy: 2e-4, "\(id) pixel \(i) channel \(c)")
            } }
            if let path = ProcessInfo.processInfo.environment["FOTUFILM_SCAN_REFERENCE_DIRECTORY"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let fixture: [String: Any] = [
                    "profile": try JSONSerialization.jsonObject(with: request),
                    "pack": pack.base64EncodedString(), "finish": finish,
                    "scan": scan.interleavedRGB(), "positive": positive.interleavedRGB(),
                ]
                try JSONSerialization.data(withJSONObject: fixture).write(to: directory.appendingPathComponent("\(id).json"))
            }
        }
    }

    /// The light an enlarger or a scan carries into the print reaches the browser's profile as
    /// the desktop host's edit carries it.
    func testTheEditsLightReachesTheProfileAsOnTheDesktop() throws {
        let width = 32, height = 24
        let stock = try printed("gold200")
        let light: [String: Double] = ["ev": 0.75, "temperature": 4800, "tint": 0.002]
        let reading = try NegativeScanPrint.Reading(
            stock: stock, border: SIMD3(0.4, 0.6, 0.2),
            balance: ApproximateNegativeScan.balance(stock: stock, denseEnd: SIMD3(1.1, 1.0, 0.9)))
        for medium in ["screen", "crystal-archive"] {
            let pack = try WebRenderRequest.prepare(profile(medium: medium, light: light))
            let options = reading.printing(try edit("gold200", medium: medium, light: light)
                .options(for: stock), stock: stock)
            XCTAssertEqual(pack, try WebFilmProfile.prepare(stock: stock, options: options,
                                                            width: width, height: height), medium)
        }
        XCTAssertThrowsError(try WebRenderRequest.prepare(profile(light: ["highlights": 1])))
    }

    func testAFrameTooSmallToMeterIsReadUnbalanced() throws {
        let stock = try printed("gold200")
        let (_, options) = try JSONDecoder().decode(WebProfileRequest.self,
                                                    from: profile(denseEnd: nil)).configured()
        XCTAssertNil(options.sceneHighlightStops)
        XCTAssertEqual(options.scanReading,
                       try ApproximateNegativeScan(stock: stock, border: SIMD3(0.4, 0.6, 0.2)))
    }

    func testRejectsMissingBorderAndReversal() throws {
        for border: [Float] in [[], [1, 1], [1, 0, 1], [-1, 1, 1]] {
            XCTAssertThrowsError(try WebRenderRequest.prepare(profile(border: border)))
        }
        XCTAssertThrowsError(try WebRenderRequest.prepare(profile(denseEnd: [1, 1])))
        let reversal = try XCTUnwrap(FilmStock.presetDefinitions.first { $0.value.stock.isReversal }?.key)
        XCTAssertThrowsError(try WebRenderRequest.prepare(profile(stock: reversal)))
    }
}
