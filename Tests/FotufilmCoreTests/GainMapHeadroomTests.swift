#if canImport(CoreImage) && canImport(ImageIO)
import XCTest
import CoreImage
import CoreGraphics
import ImageIO
@testable import FotufilmImaging

final class GainMapHeadroomTests: XCTestCase {
    @available(iOS 18.0, macOS 15.0, *)
    private func writeGainMapHEIF(headroom: Float, to url: URL) throws {
        let side = 32
        var base = [Float](repeating: 0, count: side * side * 4)
        var alternate = base
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                let value = Float(x) / Float(side - 1)
                for channel in 0..<3 {
                    base[index + channel] = value
                    alternate[index + channel] = value * headroom
                }
                base[index + 3] = 1
                alternate[index + 3] = 1
            }
        }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        func image(_ pixels: [Float]) -> CIImage {
            CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) },
                    bytesPerRow: side * 16,
                    size: CGSize(width: side, height: side),
                    format: .RGBAf, colorSpace: linear)
        }
        try CIContext(options: [.cacheIntermediates: false])
            .writeHEIFRepresentation(
                of: image(base), to: url, format: .RGB10,
                colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                options: [.hdrImage: image(alternate), .hdrGainMapAsRGB: true])
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gainmap-\(UUID().uuidString).heic")
    }

    func testDeclaredHeadroomMatchesThePlatformsOwnReport() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("gain-map headroom needs iOS 18 / macOS 15")
        }
        // The exact ceiling in the file is the writer's to choose — ImageIO derives it from the
        // encoded pair rather than passing the caller's number through — so what is pinned here
        // is that the reader returns the file's own number, digit for digit.
        var declared: [Float] = []
        for requested in [Float(2), 4, 8] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            try writeGainMapHEIF(headroom: requested, to: url)

            let read = try XCTUnwrap(
                GainMapHeadroom.declared(url: url),
                "no declaration read back from a \(requested)x gain map")
            let platform = try XCTUnwrap(
                CIImage(contentsOf: url, options: [.expandToHDR: true])?
                    .contentHeadroom)
            XCTAssertEqual(read, platform, accuracy: 1e-4,
                           """
                           the file says \(read)x and the platform says \(platform)x \
                           for the same \(requested)x gain map
                           """)
            declared.append(read)
        }
        // And it is read out of each file rather than stood in for: three pictures written a stop
        // apart come back a stop apart.
        XCTAssertEqual(declared[1] / declared[0], 2, accuracy: 0.1,
                       "\(declared) did not keep the ladder's spacing")
        XCTAssertEqual(declared[2] / declared[1], 2, accuracy: 0.1,
                       "\(declared) did not keep the ladder's spacing")
    }

    func testDeclaredHeadroomTracksTheFileRatherThanAFixedCeiling() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("gain-map headroom needs iOS 18 / macOS 15")
        }
        let modest = temporaryURL(), bright = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: modest)
            try? FileManager.default.removeItem(at: bright)
        }
        try writeGainMapHEIF(headroom: 2, to: modest)
        try writeGainMapHEIF(headroom: 8, to: bright)

        let low = try XCTUnwrap(GainMapHeadroom.declared(url: modest))
        let high = try XCTUnwrap(GainMapHeadroom.declared(url: bright))
        XCTAssertLessThan(low, PrintEncoding.hdrHeadroom,
                          "a 2x picture read back at or above the HLG ceiling")
        XCTAssertGreaterThan(high, PrintEncoding.hdrHeadroom,
                             "an 8x picture read back at or below the HLG ceiling")
        XCTAssertEqual(high / low, 4, accuracy: 0.2,
                       "the two ceilings did not keep their four-stop separation")
    }

    func testAPlainSDRPictureDeclaresNothing() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let side = 8
        var pixels = [Float](repeating: 0.5, count: side * side * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 1 }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let image = CIImage(
            bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: side * 16, size: CGSize(width: side, height: side),
            format: .RGBAf, colorSpace: linear)
        try CIContext(options: [.cacheIntermediates: false])
            .writeHEIFRepresentation(
                of: image, to: url, format: .RGB10,
                colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                options: [:])
        XCTAssertNil(GainMapHeadroom.declared(url: url),
                     "an SDR picture declared headroom it does not have")
    }

    func testRubbishDeclaresNothing() {
        XCTAssertNil(GainMapHeadroom.declared(data: Data([0, 1, 2, 3, 4, 5])))
    }
}
#endif
