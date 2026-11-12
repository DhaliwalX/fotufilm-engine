import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebNegativeProfileRequestTests: XCTestCase {
    private func definition(_ id: String) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(FilmStock.presetDefinitions[id])))
    }

    private func profile(stock id: String = "gold200", border: [Float] = [0.4, 0.6, 0.2],
                         denseEnd: [Float]? = [1.1, 1.0, 0.9], width: Int = 32, height: Int = 24,
                         medium: String = "screen", light: [String: Double]? = nil,
                         crosstalk: Float? = nil, scanLight: String? = nil,
                         reading: [String: Any] = [:]) throws -> Data {
        var negative: [String: Any] = reading.merging(["border": border]) { $1 }
        if let denseEnd { negative["denseEnd"] = denseEnd }
        if let light { negative["light"] = light }
        if let crosstalk { negative["crosstalk"] = crosstalk }
        if let scanLight { negative["scanLight"] = scanLight }
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

    /// The browser's profile reads the scan with the edit's crosstalk correction, balanced on
    /// its frame read the same way, as the desktop host reads it.
    func testTheCrosstalkCorrectionReachesTheReading() throws {
        let stock = try printed("gold200")
        let (_, options) = try JSONDecoder().decode(WebProfileRequest.self,
                                                    from: profile(crosstalk: 0.6, scanLight: "rgb"))
            .configured()
        let dense = SIMD3<Float>(1.1, 1.0, 0.9)
        XCTAssertEqual(options.scanReading, try NegativeScanPrint.Reading(
            stock: stock, border: SIMD3(0.4, 0.6, 0.2),
            balance: ApproximateNegativeScan.balance(
                stock: stock, denseEnd: dense, correction: .init(strength: 0.6, light: .rgb))).calibration)
        XCTAssertNotEqual(options.scanReading?.weights,
                          try ApproximateNegativeScan(stock: stock, border: SIMD3(0.4, 0.6, 0.2)).weights)
        XCTAssertThrowsError(try WebRenderRequest.prepare(profile(crosstalk: 1.2)))
        XCTAssertThrowsError(try WebRenderRequest.prepare(profile(crosstalk: 0.5, scanLight: "uv")))
    }

    /// An edit made with the current reading reaches the browser's profile as the desktop host
    /// reads it: through the scan's light and camera, balanced as the edit says.
    func testTheCurrentReadingReachesTheProfile() throws {
        let stock = try printed("gold200")
        let border = SIMD3<Float>(0.4, 0.6, 0.2), dense = SIMD3<Float>(1.1, 1.0, 0.9)
        let roll = ApproximateNegativeScan.RollBalance(colour: [0.94, 1.08], frames: 12, level: 1.2,
                                                       slopes: [0.9, 1.1])
        let source = NegativeScanSource(
            camera: CameraIdentity(spectralProfileID: "sony-ilce-7cm2"), kelvin: 5400, white: [0.34, 0.36],
            matrix: [1.18, -0.09, -0.09, -0.04, 1.52, -0.48, 0.01, -0.25, 1.24])
        func object(_ value: some Encodable) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        let edits: [(WebNativeEdit.Negative, NegativeScanSource?)] = [
            (.init(reading: 2), nil),
            (.init(roll: roll, crosstalk: 0.5, scanLight: .screen, reading: 2, camera: "scanner",
                   balance: .roll, neutral: [0.05, 0.06, 0.03]), nil),
            (.init(roll: roll, reading: 2), source),
            // The first reading takes a roll's colour from the request too.
            (.init(roll: roll, crosstalk: 0.4), nil),
        ]
        for (edit, source) in edits {
            var reading = try XCTUnwrap(object(edit) as? [String: Any])
            if let source { reading["source"] = try object(source) }
            let request = try profile(reading: reading)
            let (_, options) = try JSONDecoder().decode(WebProfileRequest.self, from: request).configured()
            let balance = edit.balance(stock: stock, border: border, denseEnd: dense, source: source)
            XCTAssertEqual(options.scanReading, try NegativeScanPrint.Reading(
                stock: stock, border: border, balance: balance).calibration)
            XCTAssertNotEqual(balance, ApproximateNegativeScan.balance(stock: stock, denseEnd: dense))

            // The same request read without a film.
            var plain = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            plain["kind"] = "negative-plain"
            let found = try JSONDecoder().decode(
                WebNegativePlainRequest.Result.self,
                from: WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: plain)))
            let expected = edit.plain(border: border, denseEnd: dense, source: source)
            XCTAssertEqual(found, WebNegativePlainRequest.Result(expected))
        }
        // The camera the file names changes the reading only with its decoder's matrix.
        XCTAssertNotEqual(edits[2].0.balance(stock: stock, border: border, denseEnd: dense, source: source),
                          edits[2].0.balance(stock: stock, border: border, denseEnd: dense))
    }

    /// The browser's builder carries no measured cameras: a request brings the record of the
    /// camera its scan names, and the reading then takes that camera as the desktop host does.
    func testARequestBringsItsCamerasMeasuredChannels() throws {
        let camera = CameraIdentity(make: "Fotufilm Test", model: "Scan One")
        let source = NegativeScanSource(
            camera: camera, kelvin: 5400, white: [0.34, 0.36],
            matrix: [1.18, -0.09, -0.09, -0.04, 1.52, -0.48, 0.01, -0.25, 1.24])
        func band(_ wavelength: Double, _ peak: Double) -> Double {
            exp(-0.5 * pow((wavelength - peak) / 35, 2))
        }
        var samples: [String: [Double]] = [:]
        for wavelength in stride(from: 380.0, through: 780, by: 5) {
            samples["\(Int(wavelength))"] = [band(wavelength, 600), band(wavelength, 540),
                                             band(wavelength, 460)]
        }
        let record = String(decoding: try JSONSerialization.data(withJSONObject: [
            "header": ["manufacturer": "Fotufilm Test", "model": "Scan One"],
            "spectral_data": ["index": ["main": ["R", "G", "B"]], "data": ["main": samples]],
        ] as [String: Any]), as: UTF8.self)
        func named(_ request: [String: Any]) throws -> WebNegativeCameraRequest.Result {
            try JSONDecoder().decode(
                WebNegativeCameraRequest.Result.self,
                from: WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: request)))
        }
        let described = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])

        // Nobody has measured the camera until a request brings its record.
        XCTAssertEqual(try named(["kind": "negative-camera", "source": described]),
                       .init(id: "generic", name: nil))
        XCTAssertEqual(try named(["kind": "negative-camera"]), .init(id: "generic", name: nil))
        XCTAssertEqual(try named(["kind": "negative-camera", "source": described,
                                  "cameraProfile": "not a record"]), .init(id: "generic", name: nil))
        XCTAssertEqual(try named(["kind": "negative-camera", "source": described,
                                  "cameraProfile": record]),
                       .init(id: "fotufilm-test-scan-one", name: "Fotufilm Test Scan One"))

        // The print profile and the plain reading take the record the same way.
        let stock = try printed("gold200")
        let border = SIMD3<Float>(0.4, 0.6, 0.2), dense = SIMD3<Float>(1.1, 1.0, 0.9)
        let edit = WebNativeEdit.Negative(reading: 2)
        let request = try profile(reading: ["reading": 2, "source": described, "cameraProfile": record])
        let (_, options) = try JSONDecoder().decode(WebProfileRequest.self, from: request).configured()
        let balance = edit.balance(stock: stock, border: border, denseEnd: dense, source: source)
        XCTAssertEqual(options.scanReading, try NegativeScanPrint.Reading(
            stock: stock, border: border, balance: balance).calibration)
        XCTAssertEqual(source.setup(light: .white).camera, .profile("fotufilm-test-scan-one"))
        XCTAssertNotEqual(balance, edit.balance(stock: stock, border: border, denseEnd: dense))
    }

    /// The stray light the browser resolved reaches the print's reading and the plain one.
    func testARequestsStrayLightIsTakenOffTheReading() throws {
        let stock = try printed("gold200")
        let border = SIMD3<Float>(0.4, 0.6, 0.2), dense = SIMD3<Float>(1.1, 1.0, 0.9)
        let flare = SIMD3<Float>(0.002, 0.003, 0.001)
        let edit = WebNativeEdit.Negative(reading: 2)
        let reading: [String: Any] = ["reading": 2, "strayLight": [0.002, 0.003, 0.001]]
        let request = try profile(reading: reading)
        let (_, options) = try JSONDecoder().decode(WebProfileRequest.self, from: request).configured()
        let expected = try NegativeScanPrint.Reading(
            stock: stock, border: border,
            balance: edit.balance(stock: stock, border: border, denseEnd: dense, flare: flare),
            flare: flare).calibration
        XCTAssertEqual(options.scanReading, expected)
        XCTAssertEqual(expected.flare, [0.002, 0.003, 0.001])

        var plain = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        plain["kind"] = "negative-plain"
        let found = try JSONDecoder().decode(
            WebNegativePlainRequest.Result.self,
            from: WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: plain)))
        XCTAssertEqual(found, WebNegativePlainRequest.Result(
            edit.plain(border: border, denseEnd: dense, flare: flare)))
        XCTAssertEqual(found.flare, [0.002, 0.003, 0.001])
        XCTAssertEqual(found.border[0], border.x - flare.x)
        XCTAssertGreaterThan(found.toe, 0)

        // The first reading takes none off, and stray light a scan could not carry is refused.
        let (_, first) = try JSONDecoder().decode(
            WebProfileRequest.self, from: profile(reading: ["strayLight": [0.002, 0.003, 0.001]]))
            .configured()
        XCTAssertEqual(first.scanReading?.flare, [0, 0, 0])
        for invalid: [Double] in [[0.002, 0.003], [-0.001, 0, 0], [0.3, 0, 0]] {
            XCTAssertThrowsError(try WebRenderRequest.prepare(
                profile(reading: ["reading": 2, "strayLight": invalid])), "\(invalid)")
        }
    }

    func testRejectsAReadingTheEditCouldNotKeep() throws {
        let invalid: [[String: Any]] = [
            ["reading": 0], ["reading": 2, "neutral": [0.05, 0.06]],
            ["reading": 2, "neutral": [0.05, 0, 0.03]], ["reading": 2, "balance": "page"],
            ["reading": 2, "roll": ["colour": [1, -1], "frames": 4]],
        ]
        for reading in invalid {
            XCTAssertThrowsError(try WebRenderRequest.prepare(profile(reading: reading)), "\(reading)")
            var plain: [String: Any] = ["kind": "negative-plain"]
            plain["negative"] = reading.merging(["border": [0.4, 0.6, 0.2]]) { $1 }
            XCTAssertThrowsError(
                try WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: plain)), "\(reading)")
        }
        XCTAssertThrowsError(try WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: [
            "kind": "negative-plain", "negative": ["border": [0.4, 0, 0.2]],
        ] as [String: Any])))
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
