import XCTest
import FotufilmCore
import FotufilmEditModel
#if canImport(ImageIO)
import FotufilmImaging
import ImageIO
import UniformTypeIdentifiers
#endif
@testable import FotufilmHost

final class HostRenderParityTests: XCTestCase {
    private func edit(_ extra: String = "", profile: String = "") throws -> WebNativeEdit {
        try JSONDecoder().decode(WebNativeEdit.self, from: Data("""
        {"edit":{"stock":"gold200","params":{}\(extra)},
         "profileRequest":{"controls":{}\(profile)}}
        """.utf8))
    }

    #if canImport(ImageIO)
    func testSensorMetadataAgreesForNamedFileAndHintedBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30,
            bitsPerComponent: 8, bytesPerRow: 160, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let target = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifFocalLength: 6,
            kCGImagePropertyExifFocalLenIn35mmFilm: 26,
        ]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(target))
        let named = try XCTUnwrap(SensorFrame.read(url: url))
        XCTAssertEqual(SensorFrame.read(data: try Data(contentsOf: url),
                                       identifierHint: UTType.jpeg.identifier), named)
    }
    #endif

    /// A reduced picture is sized as the Mac app's `FilmRender` sizes it: the long edge of the
    /// cropped picture, rounded outward as Core Image rounds, an upright crop cut on whole pixels.
    func testReducedSizesFollowTheMacApp() throws {
        var geometry = SceneGeometry()
        // 2848 x 512/4288 is 340.06 rows; Core Image's extent, and the Mac app's, holds 341.
        XCTAssertTrue(geometry.sizes(width: 4288, height: 2848, maxEdge: 512).output == (512, 341))
        XCTAssertTrue(geometry.sizes(width: 4288, height: 2848, maxEdge: 4288).output == (4288, 2848))
        // A 1800 x 2248 crop at 512 is 410 x 512, not a crop of the frame at 512.
        geometry.crop = [[0.2, 0.25], [0.8, 0.25], [0.8, 0.75], [0.2, 0.75]]
        XCTAssertTrue(geometry.sizes(width: 3000, height: 4496, maxEdge: 512).output == (410, 512))
        geometry.crop = [[0.1001, 0.2], [0.8999, 0.2], [0.8999, 0.8], [0.1001, 0.8]]
        let snapped = geometry.snapped(width: 1000, height: 500)
        XCTAssertEqual(snapped.crop, [[0.1, 0.2], [0.9, 0.2], [0.9, 0.8], [0.1, 0.8]])
        geometry.straighten = 2
        XCTAssertEqual(geometry.snapped(width: 1000, height: 500), geometry)
    }

    #if canImport(CoreImage)
    func testCoreImageResamplerDeliversTheTargetSize() throws {
        let flat = [Float](repeating: 0.25, count: 101 * 67 * 4)
        let reduced = try XCTUnwrap(CoreImageResampler().reduce(flat, width: 101, height: 67,
                                                                to: 50, 34))
        XCTAssertEqual(reduced.count, 50 * 34 * 4)
        XCTAssertEqual(reduced[(17 * 50 + 25) * 4], 0.25, accuracy: 1e-4)
    }
    #endif

    func testDraftsReduceFromTheSettledReductionAndNeverStandInForIt() throws {
        let (width, height) = (240, 120)
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = Float(x % 7) / 6
                rgba[i + 1] = Float(y % 5) / 4
                rgba[i + 2] = Float((x + y) % 3) / 2
            }
        }
        let image = HostImage(rgba: rgba, width: width, height: height, contentHeadroom: 1)
        func reduce(_ source: [Float], _ w: Int, _ h: Int, to tw: Int, _ th: Int) -> [Float] {
            HostPlatform.current.resampler?.reduce(source, width: w, height: h, to: tw, th)
                ?? AreaResample.reduce(source, width: w, height: h, to: tw, th)
        }
        let settled = image.scene(width: 120, height: 60)
        XCTAssertEqual(settled, reduce(rgba, width, height, to: 120, 60))
        let draft = image.scene(width: 50, height: 25, draft: true)
        XCTAssertEqual(draft, AreaResample.reduce(settled, width: 120, height: 60, to: 50, 25))
        // A settled picture at the draft's size is still reduced from the photograph itself.
        XCTAssertEqual(image.scene(width: 50, height: 25), reduce(rgba, width, height, to: 50, 25))
        XCTAssertNotEqual(image.scene(width: 50, height: 25), draft)
    }

    func testUnspecifiedMediumMatchesTheEditorAndExplicitPaperSurvives() throws {
        let stock = try XCTUnwrap(FilmStock.presets["gold200"])
        XCTAssertEqual(try edit().options(for: stock).paper?.id, PrintPaper.editorDefault.id)
        let explicit = try edit(profile: #", "medium":"ektacolor-edge""#)
        XCTAssertEqual(try explicit.options(for: stock).paper?.id, "ektacolor-edge")
        let catalogue = try WebStockCatalogue.entries()
        let entry = try XCTUnwrap(catalogue.first { $0["id"] as? String == "gold200" })
        XCTAssertEqual(entry["defaultMedium"] as? String,
                       PrintPaper.editorDefault.resolved(for: stock).id)
    }

    func testHalationModelReachesTheEngine() throws {
        let stock = try XCTUnwrap(FilmStock.presets["gold200"])
        XCTAssertEqual(try edit(#", "halationModel":"layered""#).options(for: stock).halationModel,
                       .layered)
        XCTAssertEqual(try edit(#", "halationModel":"legacy""#).options(for: stock).halationModel,
                       .legacy)
    }

    func testHDRRangeAndRollOffReachTheEngine() throws {
        let stock = try XCTUnwrap(FilmStock.presets["gold200"])
        let options = try JSONDecoder().decode(WebNativeEdit.self, from: Data("""
        {"edit":{"stock":"gold200","params":{}},
         "profileRequest":{"controls":{"hdrRange":0.25,"hdrRollOff":2}}}
        """.utf8)).options(for: stock)
        XCTAssertEqual(options.hdrRange, 0.25)
        XCTAssertEqual(options.hdrRollOff, 2)
        let plain = try edit().options(for: stock)
        XCTAssertEqual(plain.hdrRange, 1)
        XCTAssertEqual(plain.hdrRollOff, 1)
    }

    func testCropCoverageDoesNotChangeWithPreviewRounding() throws {
        let engine = try HostEngine()
        let service = engine.service
        let image = HostImage(rgba: [Float](repeating: 0.18, count: 301 * 199 * 4),
                              width: 301, height: 199, contentHeadroom: 1)
        let handle = service.register(image)
        func prepared(_ edge: Int, cropMode: Bool = false) throws -> HostService.Prepared {
            try service.prepare(Data("""
            {"handle":\(handle),"maxEdge":\(edge),"cropMode":\(cropMode),
             "edit":{"stock":"gold200","params":{},"crop":[[0.2,0.25],[0.8,0.25],[0.8,0.75],[0.2,0.75]]},
             "profileRequest":{"controls":{}}}
            """.utf8))
        }
        let full = try prepared(0)
        let small = try prepared(37)
        // The crop is cut on whole pixels, as the Mac app cuts it: rows 49 to 150 of 199.
        let coverage: Float = 101 / 199
        XCTAssertEqual(try XCTUnwrap(full.edit.frameCoverage), coverage, accuracy: 1e-6)
        XCTAssertEqual(small.edit.frameCoverage, full.edit.frameCoverage)
        XCTAssertEqual(try prepared(37, cropMode: true).edit.frameCoverage, 1)
        let stock = try XCTUnwrap(engine.stock("gold200"))
        XCTAssertEqual(try small.edit.options(for: stock).frameCoverage, coverage, accuracy: 1e-6)
    }
}
