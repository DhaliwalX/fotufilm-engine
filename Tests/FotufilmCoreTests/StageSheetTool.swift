#if canImport(CoreGraphics)
import XCTest
import Foundation
@testable import FotufilmCore

final class StageSheetTool: XCTestCase {
    func testWriteStageSheet() throws {
        guard let directory = ProcessInfo.processInfo.environment["FOTUFILM_STAGE_SHEET"] else {
            throw XCTSkip("set FOTUFILM_STAGE_SHEET to a directory")
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        let sourceURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment[
            "FOTUFILM_STAGE_SOURCE"] ?? "docs/assets/picnic-rec709.jpg")
        let source = try RGBAImage.read(sourceURL)
        let scene = source.sceneLinear
        let stock = try XCTUnwrap(FilmStock.named("pro400h"))

        func settings(_ stage: PipelineStage) -> FotufilmEngine.Options {
            var options = FotufilmEngine.Options()
            options.stage = stage
            options.format = FilmFormat.native(forStockID: "pro400h")
            options.seed = 0x5EED
            return options
        }

        func write(_ image: RGBAImage, _ name: String) throws {
            try image.pngData().write(to: out.appendingPathComponent(name))
        }

        try write(source, "00-source.png")

        let full = FotufilmEngine(stock: stock, options: settings(.full))
            .process(linearRGB: scene)
        try write(RGBAImage(print: full), "01-full.png")

        let negative = FotufilmEngine(stock: stock, options: settings(.negative))
            .process(linearRGB: scene)
        // The interchange is density, not a picture. What a person can look at is the light the
        // film with those densities passes — 10^-D, the frame on a light box — so that is what
        // this draws, with the base's own D-min left in: the orange mask is part of the negative.
        // The gain is the light box's brightness and nothing else; it is not in the data.
        var transmission = ImageBuffer(width: negative.width, height: negative.height)
        for channel in 0..<3 {
            for i in 0..<negative.pixelCount {
                transmission.planes[channel][i] =
                    pow(10, -negative.planes[channel][i]) * 2.5
            }
        }
        try write(RGBAImage(print: transmission), "02-negative.png")

        let printed = FotufilmEngine(stock: stock, options: settings(.print))
            .process(linearRGB: negative)
        try write(RGBAImage(print: printed), "03-print.png")

        let textured = FotufilmEngine(stock: stock, options: settings(.texture))
            .process(linearRGB: scene)
        try write(RGBAImage(print: textured), "04-texture.png")

        // Amplify the split/full difference by the same 64× factor used by the golden harness.
        try write(RGBAImage.amplifiedDifference(RGBAImage(print: full),
                                                RGBAImage(print: printed), gain: 64),
                  "05-difference-x64.png")

        // A 1:1 crop, source against texture, where grain is a grain rather than a suggestion.
        func crop(_ image: RGBAImage, x: Int, y: Int, size: Int) -> RGBAImage {
            var pixels = [UInt8](repeating: 255, count: size * size * 4)
            for row in 0..<size {
                for column in 0..<size {
                    let from = ((y + row) * image.width + x + column) * 4
                    let to = (row * size + column) * 4
                    for c in 0..<4 { pixels[to + c] = image.pixels[from + c] }
                }
            }
            return RGBAImage(width: size, height: size, pixels: pixels)
        }
        let side = min(360, min(source.width, source.height) / 2)
        let originX = source.width / 2 - side / 2
        let originY = source.height / 2 - side / 2
        try write(crop(source, x: originX, y: originY, size: side), "06-crop-source.png")
        try write(crop(RGBAImage(print: textured), x: originX, y: originY, size: side),
                  "07-crop-texture.png")
        try write(crop(RGBAImage(print: full), x: originX, y: originY, size: side),
                  "08-crop-full.png")

        print("stage sheet written to \(out.path)")
    }
}
#endif
