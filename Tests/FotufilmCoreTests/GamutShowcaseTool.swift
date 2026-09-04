import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FotufilmCore

final class GamutShowcaseTool: XCTestCase {
    func testRenderShowcase() throws {
        guard ProcessInfo.processInfo.environment["FOTUFILM_GAMUT_SHOWCASE"] != nil else {
            throw XCTSkip("set FOTUFILM_GAMUT_SHOWCASE=1 to render the A/B showcase")
        }
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")

        let outputDirectory = URL(fileURLWithPath: "/tmp/filming-gamut-showcase")
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)

        // A colour negative with a strong chroma response makes the destroyed colour easiest
        // to see; fall back to the test stock when no pack is installed.
        let stock = FilmStock.presets["ektar100"] ?? TestStocks.negative
        var options = FotufilmEngine.Options()
        options.grainScale = 0

        let width = 640, height = 300

        func cyanRamp(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let t = Float(x) / Float(width - 1)
            return SIMD3(0.30 - 0.26 * t, 0.85, 0.85)
        }

        func magentaRamp(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let t = Float(x) / Float(width - 1)
            return SIMD3(0.90, 0.16 - 0.16 * t, 0.40)
        }

        func cyanPair(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let third = width / 3
            if x < third { return SIMD3(0.20, 0.85, 0.85) }
            if x < 2 * third { return SIMD3(0.18, 0.18, 0.18) }
            return SIMD3(0.06, 0.85, 0.85)
        }

        let scenes: [(name: String, pixel: (Int, Int) -> SIMD3<Float>)] = [
            ("cyan-ramp", cyanRamp),
            ("magenta-ramp", magentaRamp),
            ("cyan-pair", cyanPair),
        ]

        for scene in scenes {
            var wide = ImageBuffer(width: width, height: height)
            var doored = ImageBuffer(width: width, height: height)
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let rgb = scene.pixel(x, y)
                    let p3 = ColorScience.linearRec2020ToDisplayP3(rgb)
                    let clamped = ColorScience.linearDisplayP3ToRec2020(
                        SIMD3(max(p3.x, 0), max(p3.y, 0), max(p3.z, 0)))
                    for c in 0..<3 {
                        wide.planes[c][index] = rgb[c]
                        doored.planes[c][index] = clamped[c]
                    }
                }
            }
            let a = FotufilmEngine(stock: stock, options: options)
                .process(linearRGB: doored)
            let b = FotufilmEngine(stock: stock, options: options)
                .process(linearRGB: wide)
            let url = outputDirectory.appendingPathComponent("\(scene.name)-A-vs-B.png")
            try writeSideBySide(a, b, to: url)
            print("wrote \(url.path)")
        }
    }

    private func writeSideBySide(_ a: ImageBuffer, _ b: ImageBuffer, to url: URL) throws {
        let divider = 4
        let width = a.width + divider + b.width
        let height = a.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        func blit(_ image: ImageBuffer, xOffset: Int) {
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let source = y * image.width + x
                    let destination = (y * width + xOffset + x) * 4
                    for c in 0..<3 {
                        let rolled = ColorScience.displayShoulder(image.planes[c][source])
                        let encoded = ColorScience.linearToSrgb(min(max(rolled, 0), 1))
                        bytes[destination + c] = UInt8(min(max(encoded * 255 + 0.5, 0), 255))
                    }
                    bytes[destination + 3] = 255
                }
            }
        }
        blit(a, xOffset: 0)
        blit(b, xOffset: a.width + divider)

        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "PNG write failed")
    }
}
