import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FotufilmCore

final class GrainABTool: XCTestCase {

    func testRenderReversalGrainAB() throws {
        guard let out = ProcessInfo.processInfo.environment["FOTUFILM_REVERSAL_GRAIN_AB_OUT"]
        else { throw XCTSkip("set FOTUFILM_REVERSAL_GRAIN_AB_OUT for the reversal comparison") }
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let side = 768
        var stock = TestStocks.reversal
        var options = FotufilmEngine.Options()
        options.format = FilmFormat(name: "grain comparison", frameHeightMM: 3)
        options.halationScale = 0
        options.paper = .screen
        options.seed = 0x5EED
        var input = ImageBuffer(width: side, height: side)
        let curve = stock.curves[1]
        for y in 0..<side {
            let net: Float = [0.25, 0.9, 2.8][min(2, y * 3 / side)]
            let exposure = 0.18 * pow(10, curve.logExposure(density: curve.dMax - net))
            for x in 0..<side {
                for c in 0..<3 { input.planes[c][y * side + x] = exposure }
            }
        }
        for (name, law) in [("before", GrainDensityLaw.dyeCloudSelwyn),
                            ("after", .dyeCloudReversal)] {
            stock.grainDensityLaw = law
            try write(FotufilmEngine(stock: stock, options: options).process(linearRGB: input),
                      to: directory.appendingPathComponent("reversal-\(name).png"))
        }
    }

    /// Opt-in review artifacts for authored populations. Input stocks and all generated
    /// evidence remain outside the source tree; this tool carries no stock calibration.
    func testExportPopulationComparison() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["FOTUFILM_POPULATION_AB_OUT"],
              let names = env["FOTUFILM_POPULATION_AB_STOCKS"] else {
            throw XCTSkip("set FOTUFILM_POPULATION_AB_OUT and _STOCKS for population evidence")
        }
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide required")
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var reports: [[String: Any]] = []
        for id in names.split(separator: ",").map(String.init) {
            let original = try XCTUnwrap(FilmStock.named(id), "stock not installed: \(id)")
            let candidates: [(String, CrystalGrainPopulation)] = [
                ("A", original.crystalGrainPopulation),
                ("B", CrystalGrainPopulation(radiusSpan: 3,
                    sublayerShares: [0.20, 0.25, 0.25, 0.30], coatingDensityScale: 1)),
                ("C", CrystalGrainPopulation(radiusSpan: 3,
                    sublayerShares: [0.20, 0.25, 0.25, 0.30], coatingDensityScale: 2)),
            ]
            for (label, profile) in candidates {
                var stock = original
                stock.crystalGrainPopulation = profile
                let models = (0..<3).map { CrystalGrainModel(stock: stock, layer: $0) }
                let rows: [[String: Any]] = models.map { model in
                    ["fitError": model.fitError, "readNetDensity": model.readNetDensity,
                     "readSigma": model.readSigma,
                     "sigmaAtAnchor": model.sigma(netDensity: model.readNetDensity),
                     "bins": model.bins.map { bin -> [String: Any] in
                         ["radiusMM": bin.cloudRadiusMM, "crystalsPerMM2": bin.crystalsPerMM2,
                          "dyePerCloud": bin.dyePerCloud, "pool": bin.pool]
                     }, "report": model.report]
                }
                reports.append(["stock": id, "variant": label, "records": rows])
                XCTAssertLessThan(models.map(\.fitError).max()!, 0.1,
                                  "candidate tone fit requires review: \(id) \(label)")
                var options = FotufilmEngine.Options()
                options.format = FilmFormat(name: "population detail", frameHeightMM: 2.4)
                options.grainModel = .crystals
                options.seed = 42
                options.halationScale = 0
                options.couplerScale = 0
                options.paper = .screen
                options.digitalReference = .referenceExposure
                let width = 1200, height = 400
                var patch = ImageBuffer(width: width, height: height)
                for y in 0..<height {
                    for x in 0..<width {
                        let tone: Float = [0.045, 0.18, 0.55][min(2, x * 3 / width)]
                        for c in 0..<3 { patch.planes[c][y * width + x] = tone }
                    }
                }
                try write(FotufilmEngine(stock: stock, options: options).process(linearRGB: patch),
                          to: directory.appendingPathComponent("\(id)-\(label)-patches.png"))
            }
        }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("population-report.json"))
    }

    private static let patchMM: Float = 6

    private static let ladder: [(pxPerMM: Float, paper: PrintPaper?)] = [
        (87, nil), (90, nil), (196, .screen), (204, .screen),
    ]

    func testRenderGrainAB() throws {
        guard let out = ProcessInfo.processInfo.environment["FOTUFILM_GRAIN_AB_OUT"] else {
            throw XCTSkip("set FOTUFILM_GRAIN_AB_OUT to render the grain A/B")
        }
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)

        let stock = FilmStock.presets["example-negative-400"]!
        for (pxPerMM, paper) in Self.ladder {
            let side = Int((Self.patchMM * pxPerMM).rounded())
            var options = FotufilmEngine.Options()
            options.format = FilmFormat(name: "grain a/b", frameHeightMM: Self.patchMM)
            options.seed = 0x46494C4D
            options.paper = paper

            // Three flat tones — a shadow, the mid-grey the granularity figure is read near,
            // and a highlight — so the grain can be read against the tone scale rather than at
            // one density only. Flat, because anything with detail in it would give the eye
            // something else to look at.
            var image = ImageBuffer(width: side, height: side)
            let tones: [Float] = [0.045, 0.18, 0.55]
            for y in 0..<side {
                let tone = tones[min(y * 3 / side, 2)]
                for x in 0..<side {
                    for channel in 0..<3 { image.planes[channel][y * side + x] = tone }
                }
            }
            let rendered = FotufilmEngine(stock: stock, options: options)
                .process(linearRGB: image)
            try write(rendered,
                      to: directory.appendingPathComponent("\(Int(pxPerMM))pxmm.png"))
        }
    }

    func testRenderPhotographAB() throws {
        guard let out = ProcessInfo.processInfo.environment["FOTUFILM_GRAIN_AB_OUT"],
              let source = ProcessInfo.processInfo.environment["FOTUFILM_GRAIN_AB_PHOTO"]
        else { throw XCTSkip("set FOTUFILM_GRAIN_AB_PHOTO and _OUT to render the photo A/B") }
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let stock = FilmStock.presets["example-negative-400"]!
        // A 35 mm frame, so the sampling density is the delivered line count over 24 mm.
        let frameMM: Float = 24
        for lines in [2088, 2160] {
            let image = try Self.scene(at: URL(fileURLWithPath: source), lines: lines)
            var options = FotufilmEngine.Options()
            options.format = FilmFormat(name: "35mm", frameHeightMM: frameMM)
            options.seed = 0x46494C4D
            let rendered = FotufilmEngine(stock: stock, options: options)
                .process(linearRGB: image)
            let pxPerMM = Int((Float(lines) / frameMM).rounded())
            try write(rendered,
                      to: directory.appendingPathComponent("photo-\(pxPerMM)pxmm.png"))
        }
    }

    private static func scene(at url: URL, lines: Int) throws -> ImageBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw XCTSkip("could not open \(url.path)") }
        let width = Int((Double(decoded.width) * Double(lines)
                         / Double(decoded.height)).rounded())
        var bytes = [UInt8](repeating: 0, count: width * lines * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: lines, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw XCTSkip("could not build a drawing context") }
        context.interpolationQuality = .high
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: lines))

        var image = ImageBuffer(width: width, height: lines)
        for index in 0..<image.pixelCount {
            for channel in 0..<3 {
                image.planes[channel][index] =
                    srgbDecodedByte[Int(bytes[index * 4 + channel])]
            }
        }
        return image
    }

    private func write(_ image: ImageBuffer, to url: URL) throws {
        var bytes = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for index in 0..<image.pixelCount {
            for channel in 0..<3 {
                let rolled = ColorScience.displayShoulder(image.planes[channel][index])
                let encoded = ColorScience.linearToSrgb(min(max(rolled, 0), 1))
                bytes[index * 4 + channel] = UInt8(min(max(encoded * 255 + 0.5, 0), 255))
            }
        }
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let made = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, made, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "PNG write failed")
    }
}
