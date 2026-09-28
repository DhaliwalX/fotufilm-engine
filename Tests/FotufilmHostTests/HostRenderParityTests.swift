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

    func testStandardRangeIsDecodedOnceAndKeepsCaptureFacts() throws {
        let image = HostImage(rgba: [2, 1, 0.5, 1], width: 1, height: 1, contentHeadroom: 4)
        let standard = HostImage(rgba: [0.8, 0.5, 0.3, 1], width: 1, height: 1, contentHeadroom: 1)
        image.sensorFrame = SensorFrame.equivalentFocal(focalLengthMM: 6, equivalent35mmMM: 26,
                                                     pixelWidth: 4000, pixelHeight: 3000)
        image.originalFile = URL(fileURLWithPath: "/synthetic/photo.heic")
        var count = 0
        image.decodeStandardRange = { count += 1; return standard }
        XCTAssertTrue(try image.interpreted(standardRange: false) === image)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try image.interpreted(standardRange: true) === standard)
        XCTAssertTrue(try image.interpreted(standardRange: true) === standard)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(standard.sensorFrame, image.sensorFrame)
        XCTAssertEqual(standard.originalFile, image.originalFile)
        XCTAssertEqual(standard.contentHeadroom, 1)
        XCTAssertTrue(try image.interpreted(standardRange: false) === image)
        XCTAssertTrue(try edit(#", "sourceInterpretation":"standardRange""#).readsStandardRange)
        XCTAssertFalse(try edit(#", "sourceInterpretation":"fullRange""#).readsStandardRange)
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
