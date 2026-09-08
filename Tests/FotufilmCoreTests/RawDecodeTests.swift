import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging
#if canImport(ImageIO)
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#endif

final class RawDecodeRecipeTests: XCTestCase {
    func testRecipeMakesEveryDevelopmentChoiceExplicitAndComparable() {
        let recipe = RawDecode.Recipe(
            neutralKelvin: 4300,
            targetLongEdge: 2048,
            correctsLens: false,
            extendedDynamicRangeAmount: 3,
            recoversHighlights: false)

        XCTAssertEqual(recipe.neutralKelvin, 4300)
        XCTAssertEqual(recipe.targetLongEdge, 2048)
        XCTAssertEqual(recipe.correctsLens, false)
        XCTAssertEqual(recipe.extendedDynamicRangeAmount, 3)
        XCTAssertFalse(recipe.recoversHighlights)
        XCTAssertEqual(recipe, recipe)
    }
}

final class RawDecodeScaleTests: XCTestCase {
    func testAPreviewDoesNotDemosaicTheWholeSensor() {
        let scale = RawDecode.scaleFactor(nativeLongEdge: 9504, targetLongEdge: 1024)
        XCTAssertEqual(scale, 2048 / 9504, accuracy: 1e-6)
    }

    func testTheMeasuredReductionAlwaysGetsTheLastFactorOfTwo() {
        for native in stride(from: Float(512), through: 12000, by: 137) {
            for target in stride(from: 256, through: 4096, by: 191) {
                let scale = RawDecode.scaleFactor(nativeLongEdge: native,
                                                  targetLongEdge: target)
                XCTAssertLessThanOrEqual(scale, 1)
                let decoded = scale * native
                XCTAssertTrue(decoded >= 2 * Float(target) - 1e-3 || scale == 1,
                              "native \(native), target \(target)")
            }
        }
    }

    func testASourceSmallerThanTheTargetIsNotEnlarged() {
        XCTAssertEqual(RawDecode.scaleFactor(nativeLongEdge: 800, targetLongEdge: 4096), 1)
    }

    func testADegenerateSizeIsLeftAlone() {
        XCTAssertEqual(RawDecode.scaleFactor(nativeLongEdge: 0, targetLongEdge: 1024), 1)
        XCTAssertEqual(RawDecode.scaleFactor(nativeLongEdge: 4000, targetLongEdge: 0), 1)
    }
}

#if canImport(ImageIO)

final class RawDecodeIdentificationTests: XCTestCase {
    private func encoded(_ type: UTType) throws -> Data {
        let width = 8, height = 8
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    func testAPNGIsNotRawEvenThoughTheRawFilterTakesIt() throws {
        let png = try encoded(.png)
        XCTAssertNotNil(CIRAWFilter(imageData: png, identifierHint: nil))
        XCTAssertFalse(RawDecode.isRaw(data: png))
        XCTAssertNil(RawDecode.metadata(data: png))
    }

    func testAJPEGIsNotRaw() throws {
        let jpeg = try encoded(.jpeg)
        XCTAssertFalse(RawDecode.isRaw(data: jpeg))
        XCTAssertNil(RawDecode.metadata(data: jpeg))
    }

    func testAHEICIsNotRaw() throws {
        let heic = try encoded(.heic)
        XCTAssertFalse(RawDecode.isRaw(data: heic))
        XCTAssertNil(RawDecode.metadata(data: heic))
    }

    func testAPickerLabelDoesNotMakeAPNGRaw() throws {
        let png = try encoded(.png)
        XCTAssertFalse(RawDecode.isRaw(data: png,
                                       identifierHint: UTType.rawImage.identifier))
        XCTAssertNil(RawDecode.metadata(data: png,
                                        identifierHint: UTType.rawImage.identifier))
    }

    func testEveryRawContainerTypeImageIOReadsIsRaw() throws {
        let readable = try XCTUnwrap(CGImageSourceCopyTypeIdentifiers() as? [String])
        let raw = readable.filter { UTType($0)?.conforms(to: .rawImage) ?? false }
        XCTAssertFalse(raw.isEmpty)
        for identifier in raw {
            XCTAssertTrue(RawDecode.isRawType(identifier), identifier)
        }
        XCTAssertTrue(raw.contains("com.adobe.raw-image"))
    }

    func testTheOrdinaryContainerTypesAreNotRaw() {
        for type in [UTType.png, .jpeg, .heic, .heif, .tiff, .gif, .image] {
            XCTAssertFalse(RawDecode.isRawType(type.identifier), type.identifier)
        }
    }

    func testAConcreteRawIdentifierWinsOverItsAbstractFamily() throws {
        let sony = try XCTUnwrap(UTType(filenameExtension: "arw"))
        XCTAssertEqual(
            RawDecode.concreteRawIdentifier(
                identifiers: [UTType.rawImage.identifier, sony.identifier]),
            sony.identifier)
    }

    func testAResourceFilenameResolvesAnAbstractPhotoKitRawType() throws {
        let sony = try XCTUnwrap(UTType(filenameExtension: "arw"))
        XCTAssertEqual(
            RawDecode.concreteRawIdentifier(
                identifiers: [UTType.tiff.identifier, UTType.rawImage.identifier],
                filenames: ["DSC00001.ARW"]),
            sony.identifier)
    }

    func testAnAbstractRawTypeWithoutAConcreteLabelIsNotAValidHint() {
        XCTAssertNil(RawDecode.concreteRawIdentifier(
            identifiers: [UTType.rawImage.identifier]))
    }

    func testAPickerLabelSpeaksForATIFFContainer() throws {
        let tiff = try encoded(.tiff)
        XCTAssertFalse(RawDecode.isRaw(data: tiff))
        XCTAssertTrue(RawDecode.isRaw(data: tiff,
                                      identifierHint: "com.sony.arw-raw-image"))
    }

    func testABundledPNGFileIsNotRaw() throws {
        let png = try encoded(.png)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawdecode-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(RawDecode.isRaw(url: url))
    }

    func testAMissingFileIsNotRaw() {
        XCTAssertFalse(RawDecode.isRaw(
            url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).arw")))
    }

    func testATIFFBasedRawIsTypedByItsNameAndNotByItsBytes() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawdecode-\(UUID().uuidString).arw")
        try encoded(.tiff).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let type = try XCTUnwrap(
            (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType)
        XCTAssertTrue(type.conforms(to: .rawImage), type.identifier)

        let data = try Data(contentsOf: url)
        XCTAssertFalse(RawDecode.isRaw(data: data))

        XCTAssertTrue(RawDecode.isRaw(data: data,
                                      identifierHint: type.identifier))
    }
}

#endif
