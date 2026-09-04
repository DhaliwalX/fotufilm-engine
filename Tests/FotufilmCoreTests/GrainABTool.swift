import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FotufilmCore

final class GrainABTool: XCTestCase {

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
