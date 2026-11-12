import XCTest
@testable import FotufilmCore

/// A scan's stray light is read from its holder only where the scan plainly shows one.
final class NegativeScanFlareTests: XCTestCase {
    private let border = SIMD3<Float>(0.8, 0.45, 0.2)
    private let width = 200, height = 140

    /// A scan whose film fills `film` (0 to 1 of each edge kept clear around it) with
    /// `density` over the clear film at each pixel, and `holder` light everywhere else.
    private func scan(margin: Float, holder: SIMD3<Float>?,
                      density: (Float, Float) -> SIMD3<Float>) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let u = (Float(x) + 0.5) / Float(width), v = (Float(y) + 0.5) / Float(height)
            let i = y * width + x
            let inside = u > margin && u < 1 - margin && v > margin && v < 1 - margin
            let d = density(u, v)
            for c in 0..<3 {
                if let holder, !inside {
                    // The holder's light is even but not flat.
                    image.planes[c][i] = holder[c] * (1 + 0.1 * (u - 0.5))
                } else {
                    image.planes[c][i] = border[c] * pow(10, -d[c])
                }
            }
        } }
        return image
    }

    /// A picture: darker to denser across it, with some colour.
    private func picture(_ u: Float, _ v: Float) -> SIMD3<Float> {
        SIMD3(0.2 + 1.3 * u, 0.25 + 1.5 * u * (0.7 + 0.3 * v), 0.3 + 1.7 * u)
    }

    func testAHoldersLightIsTheScansStrayLight() throws {
        let stray = border * 0.0006
        let image = scan(margin: 0.12, holder: stray, density: picture)
        let found = try XCTUnwrap(ApproximateNegativeScan.strayLight(border: border, preview: image))
        for c in 0..<3 { XCTAssertEqual(found[c], stray[c], accuracy: 0.06 * stray[c]) }
        // The frame's average light is the picture's, which the holder stays out of.
        let light = try XCTUnwrap(ApproximateNegativeScan.frameLight(preview: image))
        let all = try XCTUnwrap(ApproximateNegativeScan.frameLight(
            preview: scan(margin: 0, holder: nil, density: picture)))
        for c in 0..<3 {
            XCTAssertGreaterThan(light[c], 20 * found[c])
            XCTAssertEqual(light[c], all[c], accuracy: 0.25 * all[c])
        }
    }

    func testAScanThatShowsNoHolderHasNoneToMeasure() {
        // The film fills the scan.
        XCTAssertNil(ApproximateNegativeScan.strayLight(
            border: border, preview: scan(margin: 0, holder: nil, density: picture)))
        // A dense sky along the top edge reaches into the middle: film, not holder.
        XCTAssertNil(ApproximateNegativeScan.strayLight(
            border: border, preview: scan(margin: 0, holder: nil) { u, v in
                v < 0.35 ? SIMD3(2.2, 2.4, 2.6) : self.picture(u, v)
            }))
        // A lamp at the picture's corner: denser than anything else, but too small.
        XCTAssertNil(ApproximateNegativeScan.strayLight(
            border: border, preview: scan(margin: 0, holder: nil) { u, v in
                u < 0.08 && v < 0.08 ? SIMD3(repeating: 2.9) : self.picture(u, v)
            }))
        // A grey mask around the film, no darker than the picture's densest film.
        XCTAssertNil(ApproximateNegativeScan.strayLight(
            border: border, preview: scan(margin: 0.12, holder: border * 0.02, density: picture)))
        // A holder that shows no light at all has none to take off.
        XCTAssertNil(ApproximateNegativeScan.strayLight(
            border: border, preview: scan(margin: 0.12, holder: .zero, density: picture)))
        // Too small a scan, or no clear film to read against.
        XCTAssertNil(ApproximateNegativeScan.strayLight(
            border: border, preview: ImageBuffer(width: 8, height: 8)))
        XCTAssertNil(ApproximateNegativeScan.strayLight(
            border: SIMD3(0.8, 0, 0.2),
            preview: scan(margin: 0.12, holder: border * 0.0006, density: picture)))
        XCTAssertNil(ApproximateNegativeScan.frameLight(preview: ImageBuffer(width: 1, height: 1)))
    }

    func testStrayLightIsNoMoreThanAScansIsSetTo() throws {
        // A thin picture, whose holder is a stop darker than its densest film but lighter than
        // a fiftieth of its average light.
        let thin = { (u: Float, v: Float) in SIMD3<Float>(repeating: 0.05 + 0.5 * u) }
        let image = scan(margin: 0.12, holder: border * 0.1, density: thin)
        let found = try XCTUnwrap(ApproximateNegativeScan.strayLight(border: border, preview: image))
        let light = try XCTUnwrap(ApproximateNegativeScan.frameLight(preview: image))
        for c in 0..<3 {
            XCTAssertLessThan(found[c], 0.5 * border[c] * 0.1)
            XCTAssertEqual(found[c], ApproximateNegativeScan.flareShares.upperBound * light[c],
                           accuracy: 0.3 * found[c])
        }
    }
}
