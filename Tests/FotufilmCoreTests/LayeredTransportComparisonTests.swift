#if canImport(CoreGraphics) && canImport(ImageIO)
import Foundation
import XCTest
@testable import FotufilmCore

final class LayeredTransportComparisonTests: XCTestCase {
    /// Opt-in reproducible render. All source pixels and the optical construction are synthetic.
    func testWriteComparison() throws {
        guard let path = ProcessInfo.processInfo.environment["FOTUFILM_TRANSPORT_AB_OUTPUT"] else {
            throw XCTSkip("Set FOTUFILM_TRANSPORT_AB_OUTPUT to write the comparison")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let w = 960, h = 600
        var scene = ImageBuffer(width: w, height: h, fill: 0.012)
        // A dark architectural target, neutral luminaires, fine bars, and coloured lights.
        // Values are linear Rec.2020. Highlights deliberately exceed diffuse white.
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x
            let sky = 0.009 + Float(h-y)/Float(h)*0.008
            var rgb: [Float] = [sky*0.75, sky*0.9, sky*1.25]
            if y > 385 {
                let v = 0.015 + 0.018*Float((x/55+y/35)%2)
                rgb = [v, v*0.93, v*0.85]
            }
            if (100..<860).contains(x) && (110..<400).contains(y) {
                let brick = Float((x/36+y/18)%2)*0.006
                rgb = [0.036+brick, 0.027+brick, 0.021+brick]
            }
            for center in [200, 480, 760] {
                if abs(x-center) < 78 && (180..<335).contains(y) { rgb = [0.006, 0.007, 0.009] }
                if abs(x-center) < 72 && (170..<178).contains(y) { rgb = [96, 96, 96] }
                if abs(x-center) < 2 && (250..<440).contains(y) { rgb = [0.07, 0.07, 0.07] }
            }
            if y > 195 && y < 325 && x > 120 && x < 280 && (x-120)%20 < 3 { rgb = [1.5, 1.5, 1.5] }
            let discs: [(Int, Int, Float, [Float])] = [
                (190, 485, 9, [24,24,24]), (335,485,7,[96,96,96]),
                (480,485,5,[384,384,384]), (625,485,8,[96,12,1]), (770,485,8,[1,12,96])]
            for (cx, cy, radius, colour) in discs {
                let dx = Float(x-cx), dy = Float(y-cy)
                let coverage = min(max(radius+0.5-sqrt(dx*dx+dy*dy), 0), 1)
                if coverage > 0 { rgb = zip(rgb,colour).map { (1-coverage)*$0 + coverage*$1 } }
            }
            for c in 0..<3 { scene.planes[c][i] = rgb[c] }
        } }
        var stock = TestStocks.negative; stock.adjacencyStrength = 0
        var options = TransportFixtures.quiet
        options.localTone = false
        // The same gauge, strengths, scene transform, development, and print for both models.
        var timings = [String: Double]()
        func render(_ name: String, _ settings: FotufilmEngine.Options) throws -> ImageBuffer {
            let start = Date()
            let image = try FotufilmEngine(stock: stock, options: settings).processChecked(linearRGB: scene)
            timings[name] = Date().timeIntervalSince(start)
            try RGBAImage(print: image).pngData().write(to: directory.appendingPathComponent(name+".png"))
            return image
        }
        let a = try render("legacy", options)
        options.layeredTransport = TransportFixtures.stack
        let b = try render("layered", options)
        options.transportBackend = .metal
        var parity: Float = 0
        if TransportBackend.metal.isAvailable {
            let gpu = try render("layered-metal", options)
            for c in 0..<3 { for i in 0..<scene.pixelCount {
                parity = max(parity, abs(b.planes[c][i] - gpu.planes[c][i]))
            } }
            XCTAssertLessThan(parity, 0.0001)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(TransportFixtures.stack).write(to: directory.appendingPathComponent("construction.json"))
        let report: [String: Any] = ["width": w, "height": h, "scene": "synthetic HDR architectural target",
            "stock": stock.name, "constructionProvenance": "illustrative",
            "amount": 1, "returnedToDirect": stock.halationStrength,
            "format": options.format.name, "metalMaximumAbsoluteDifference": parity,
            "coldCPUAndWarmMetalSeconds": timings,
            "meanAbsoluteABDifference": zip(a.planes.flatMap{$0}, b.planes.flatMap{$0})
                .reduce(0.0) { $0 + Double(abs($1.0-$1.1)) } / Double(scene.pixelCount*3)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("metrics.json"))
    }
}
#endif
