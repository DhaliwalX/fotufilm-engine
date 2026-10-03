import XCTest
@testable import FotufilmCore

/// A lab scan holds colour in a frame's shadows: only the no-light floor itself is timed neutral.
final class LabScanShadowColourTests: XCTestCase {
    private func scanned(_ shadow: SIMD3<Float>, stock: FilmStock) -> SIMD3<Float> {
        // Half the frame mid-grey, so the setup meters a normal frame; half the shadow colour.
        var image = ImageBuffer(width: 32, height: 16)
        for y in 0..<16 { for x in 0..<32 {
            let colour = x < 16 ? SIMD3<Float>(repeating: 0.18) : shadow
            let scene = ColorScience.linearSRGBToRec2020(colour)
            for c in 0..<3 { image.planes[c][y * 32 + x] = scene[c] }
        }}
        var options = FotufilmEngine.Options()
        options.paper = .labScan
        options.grainScale = 0
        options.halationScale = 0
        options.flareScale = 0
        options.localTone = false
        options.labScanLook = 0
        options.labScanDodging = 0
        let output = FotufilmEngine(stock: stock, options: options).process(linearRGB: image)
        let index = 8 * 32 + 28
        return SIMD3(output.planes[0][index], output.planes[1][index], output.planes[2][index])
    }

    func testDarkColoursKeepTheirColourAndDarkGreysStayNeutral() {
        let stock = TestStocks.negative
        let level = 0.18 * pow(Float(2), -3)
        let brown = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(
            scanned(level * SIMD3(1, 0.62, 0.38), stock: stock)))
        let chroma = (brown.y * brown.y + brown.z * brown.z).squareRoot()
        let hue = atan2(brown.z, brown.y) * 180 / .pi
        XCTAssertGreaterThan(chroma, 0.025, "a brown three stops down scans grey: \(brown)")
        XCTAssertTrue((20...100).contains(hue), "the brown's hue moved to \(hue)°")
        let grey = scanned(SIMD3(repeating: level), stock: stock)
        let lab = LabScanFinish.oklab(ColorScience.linearDisplayP3ToSRGB(grey))
        XCTAssertLessThan((lab.y * lab.y + lab.z * lab.z).squareRoot(), chroma / 3,
                          "a grey three stops down took a cast: \(grey)")
    }
}
