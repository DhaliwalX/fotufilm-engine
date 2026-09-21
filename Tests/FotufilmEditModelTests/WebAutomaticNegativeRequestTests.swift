import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebAutomaticNegativeRequestTests: XCTestCase {
    func testSharedAnalysisAndNativeReference() throws {
        for mono in [false, true] {
            let width = 640, height = 16
            var scene = ImageBuffer(width: width, height: height)
            for y in 0..<height { for x in 0..<width {
                let t = Float(x) / Float(width - 1)
                let scan = SIMD3<Float>(0.02 + t * 0.68, 0.01 + t * 0.33, 0.003 + t * 0.15)
                let rgb = ColorScience.linearSRGBToRec2020(scan)
                for c in 0..<3 { scene.planes[c][y * width + x] = rgb[c] }
            } }
            var sample = ImageBuffer(width: width / 2, height: height / 2)
            for y in 0..<sample.height { for x in 0..<sample.width { for c in 0..<3 {
                sample.planes[c][y * sample.width + x] = scene.planes[c][2*y*width + 2*x]
            } } }
            let request: [String: Any] = ["kind": "negative-auto", "width": sample.width,
                "height": sample.height, "planes": sample.planes, "monochrome": mono, "rec2020": true]
            let response = try WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: request))
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            XCTAssertEqual((result["parameters"] as? [NSNumber])?.count, 8)
            for i in 0..<sample.pixelCount {
                let rgb = AutomaticNegativeScan.rec2020ToSRGB(SIMD3(sample.planes[0][i], sample.planes[1][i], sample.planes[2][i]))
                for c in 0..<3 { sample.planes[c][i] = rgb[c] }
            }
            let plan = try AutomaticNegativeScan(preview: sample, monochrome: mono)
            let direct = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? NSDictionary)
            XCTAssertEqual(direct, result as NSDictionary)
            // Optional cross-runtime fixtures contain synthetic data only.
            if let path = ProcessInfo.processInfo.environment["FOTUFILM_SCAN_REFERENCE_DIRECTORY"] {
                var scan = scene
                for i in 0..<scene.pixelCount {
                    let rgb = AutomaticNegativeScan.rec2020ToSRGB(SIMD3(scene.planes[0][i], scene.planes[1][i], scene.planes[2][i]))
                    for c in 0..<3 { scan.planes[c][i] = rgb[c] }
                }
                let positive = try plan.convert(scan, useMetal: false)
                var expected = [Float]()
                for i in 0..<positive.pixelCount {
                    let rgb = ColorScience.linearSRGBToRec2020(SIMD3(positive.planes[0][i], positive.planes[1][i], positive.planes[2][i]))
                    expected.append(contentsOf: [rgb.x, rgb.y, rgb.z, 1])
                }
                let fixture: [String: Any] = ["request": request, "plan": result, "input": scene.planes,
                    "width": width, "height": height, "expected": expected]
                let url = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: fixture).write(to: url.appendingPathComponent("automatic-\(mono ? "mono" : "color").json"))
            }
        }
    }
    func testMalformedAndEmptyScansFailWithoutTrapping() throws {
        for request: [String: Any] in [
            ["kind":"negative-auto", "width":512, "height":512, "planes":[[1],[1],[1]], "monochrome":false, "rec2020":false],
            ["kind":"negative-auto", "width":2, "height":2, "planes":[[0,0,0,0],[0,0,0,0],[0,0,0,0]], "monochrome":true, "rec2020":false]
        ] { XCTAssertThrowsError(try WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: request))) }
    }
}
