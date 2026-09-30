// Independent ImageIO/Core Image reference for the synthetic fixtures from test-tiff-codec.sh.
// Host-only. Exotic layouts have separate source-value tests in tiff-codec-test.cpp.
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
let names = (1...8).map { "classic-\($0)" }
    + ["simple-alpha-1", "simple-alpha-2", "float-16", "float-32", "grey-1", "grey-8", "precision"]
var checked = 0
var largest: Float = 0
for name in names {
    let url = root.appendingPathComponent(name + ".tif")
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
        fatalError("ImageIO could not read \(name)")
    }
    let w = Int(image.extent.width), h = Int(image.extent.height)
    let size = try String(contentsOf: root.appendingPathComponent(name + ".size"), encoding: .utf8)
        .split(separator: " ").compactMap { Int($0) }
    precondition(size == [w, h], "Upright geometry differs for \(name)")
    let data = try Data(contentsOf: root.appendingPathComponent(name + ".rgba"))
    precondition(data.count == w * h * 16)
    let decoded = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    var apple = [Float](repeating: 0, count: decoded.count)
    context.render(image, toBitmap: &apple, rowBytes: w * 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
    let maximum = zip(decoded, apple).map { abs($0 - $1) }.max()!
    // Float fixtures reach 4.8 scene-linear units; the other fixtures are SDR.
    let tolerance: Float = name.hasPrefix("float-") ? 0.0002 : 0.00004
    precondition(maximum.isFinite && maximum <= tolerance, "\(name): maximum linear error \(maximum)")
    largest = max(largest, maximum); checked += 1
    if name == "classic-1" {
        // Side-by-side preview for visual inspection: portable decoder left, Core Image right.
        var comparison = [Float](); comparison.reserveCapacity(w * h * 8)
        for row in 0..<h {
            comparison.append(contentsOf: decoded[(row * w * 4)..<((row + 1) * w * 4)])
            comparison.append(contentsOf: apple[(row * w * 4)..<((row + 1) * w * 4)])
        }
        let pixels = comparison.withUnsafeBytes { Data($0) }
        let pair = CIImage(bitmapData: pixels, bytesPerRow: w * 32, size: CGSize(width: w * 2, height: h), format: .RGBAf, colorSpace: space)
        let cg = context.createCGImage(pair, from: pair.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)!
        let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("apple-comparison.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
}
print("TIFF Apple host reference: \(checked) fixtures passed; maximum linear error \(largest)")
