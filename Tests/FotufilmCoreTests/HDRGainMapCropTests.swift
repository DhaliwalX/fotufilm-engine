#if canImport(CoreImage) && canImport(ImageIO)
import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import FotufilmImaging

final class HDRGainMapCropTests: XCTestCase {
    func testCropKeepsGainMapGeometryAndCalibratedColour() throws {
        guard #available(macOS 15, *) else {
            throw XCTSkip("writing an HDR target gain map requires macOS 15")
        }
        let width = 96, height = 64
        let linearP3 = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let displayP3 = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.displayP3))
        let sdrPatch = SIMD3<Float>(0.4, 0.2, 0.1)
        let hdrPatch = SIMD3<Float>(1.6, 0.8, 0.4)
        func image(_ patch: SIMD3<Float>) -> CIImage {
            var pixels = [Float](repeating: 1, count: width * height * 4)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                pixels[index] = patch.x
                pixels[index + 1] = patch.y
                pixels[index + 2] = patch.z
            }
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            return CIImage(
                bitmapData: data, bytesPerRow: width * 16,
                size: CGSize(width: width, height: height),
                format: .RGBAf, colorSpace: linearP3)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-gain-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.heic")
        let croppedURL = directory.appendingPathComponent("cropped.heic")
        let context = CIContext(options: [
            .workingColorSpace: linearP3,
            .workingFormat: CIFormat.RGBAf,
        ])
        try context.writeHEIFRepresentation(
            of: image(sdrPatch), to: sourceURL, format: .RGB10,
            colorSpace: displayP3,
            options: [
                .hdrImage: image(hdrPatch),
                .hdrGainMapAsRGB: true,
            ])

        let sourceData = try Data(contentsOf: sourceURL)
        XCTAssertTrue(HDRGainMapCrop.writeCroppedHEIF(
            data: sourceData, portraitAspect: 1, to: croppedURL))
        let croppedData = try Data(contentsOf: croppedURL)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(croppedData as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int,
                       properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertNotNil(CIImage(data: croppedData, options: [
            .auxiliaryHDRGainMap: true,
        ]), "the crop flattened or detached the HDR gain map")

        let expanded = try XCTUnwrap(CIImage(
            data: croppedData, options: [.expandToHDR: true]))
        var readback = [Float](repeating: 0, count: 4)
        readback.withUnsafeMutableBytes { bytes in
            context.render(
                expanded, toBitmap: bytes.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: expanded.extent.midX,
                               y: expanded.extent.midY, width: 1, height: 1),
                format: .RGBAf, colorSpace: linearP3)
        }
        XCTAssertGreaterThan(readback[0], 1,
                             "the cropped file no longer expands above SDR white")
        XCTAssertEqual(readback[0] / readback[1],
                       hdrPatch.x / hdrPatch.y, accuracy: 0.08)
        XCTAssertEqual(readback[1] / readback[2],
                       hdrPatch.y / hdrPatch.z, accuracy: 0.08)
    }
}
#endif
