import XCTest
import FotufilmImaging

final class PreviewViewportTests: XCTestCase {
    func testBaseLongEdgeUsesDisplayPixelsAndCeiling() {
        XCTAssertEqual(PreviewViewport.baseLongEdge(
            canvasPoints: CGSize(width: 402, height: 700), displayScale: 3), 2100)
        XCTAssertEqual(PreviewViewport.baseLongEdge(
            canvasPoints: CGSize(width: 500, height: 1000), displayScale: 3), 2560)
    }

    func testCoverageComposesCropAndViewportShortEdge() throws {
        let viewport = try XCTUnwrap(PreviewViewport(
            visibleUnitRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            targetPixelSize: CGSize(width: 1000, height: 750),
            frameAspect: 4 / 3,
            baseLongEdge: 1200))
        XCTAssertEqual(viewport.frameCoverage(composedWith: 0.8), 0.4,
                       accuracy: 0.0001)
    }

    func testApronClampsAtFrameEdgeAndKeepsVirtualOrigin() throws {
        let viewport = try XCTUnwrap(PreviewViewport(
            visibleUnitRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            targetPixelSize: CGSize(width: 600, height: 400),
            frameAspect: 3 / 2,
            baseLongEdge: 1200))
            .addingSpatialSupport(24)
        XCTAssertEqual(viewport.origin.x, 0)
        XCTAssertEqual(viewport.origin.y, 0)
        XCTAssertEqual(viewport.displayCropPixelRect.minX, 0)
        XCTAssertEqual(viewport.displayCropPixelRect.minY, 0)
        XCTAssertLessThanOrEqual(viewport.renderUnitRect.maxX, 1)
        XCTAssertLessThanOrEqual(viewport.renderUnitRect.maxY, 1)

        let opposite = try XCTUnwrap(PreviewViewport(
            visibleUnitRect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            targetPixelSize: CGSize(width: 600, height: 400),
            frameAspect: 3 / 2,
            baseLongEdge: 1200))
            .addingSpatialSupport(24)
        XCTAssertEqual(opposite.renderUnitRect.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(opposite.renderUnitRect.maxY, 1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(opposite.displayCropPixelRect.maxX,
                                 opposite.renderPixelSize.width)
        XCTAssertLessThanOrEqual(opposite.displayCropPixelRect.maxY,
                                 opposite.renderPixelSize.height)
    }

    /// A pan-grid edge that lands a few ulps off its pixel must not round the published tile a
    /// pixel wider than the apron-bearing region that was developed around it.
    func testApronSurroundsTileAtEveryPanPosition() throws {
        let support = 16
        for (aspect, longEdge) in [(CGFloat(666) / 1000, 1000), (CGFloat(1000) / 666, 1000),
                                   (CGFloat(4) / 3, 4032), (CGFloat(2) / 3, 6000)] {
            let frame = aspect >= 1
                ? CGSize(width: CGFloat(longEdge), height: (CGFloat(longEdge) / aspect).rounded())
                : CGSize(width: (CGFloat(longEdge) * aspect).rounded(), height: CGFloat(longEdge))
            let unit = CGSize(width: 164 / frame.width, height: 164 / frame.height)
            for step in 1..<40 {
                let x = CGFloat(step) / 41 * (1 - unit.width)
                let y = CGFloat(40 - step) / 41 * (1 - unit.height)
                let viewport = try XCTUnwrap(PreviewViewport(
                    visibleUnitRect: CGRect(x: x, y: y, width: unit.width, height: unit.height),
                    targetPixelSize: CGSize(width: 164, height: 164),
                    frameAspect: aspect, baseLongEdge: longEdge))
                    .addingSpatialSupport(support)
                // The apron gives way only where the frame itself ends.
                let crop = viewport.displayCropPixelRect
                let origin = viewport.origin, virtual = viewport.virtualFrameSize
                let apron = CGFloat(support)
                let context = "aspect \(aspect) long edge \(longEdge) step \(step)"
                XCTAssertGreaterThanOrEqual(crop.minX, min(apron, origin.x + crop.minX), context)
                XCTAssertGreaterThanOrEqual(crop.minY, min(apron, origin.y + crop.minY), context)
                XCTAssertLessThanOrEqual(min(crop.maxX + apron, virtual.width - origin.x),
                                         viewport.renderPixelSize.width, context)
                XCTAssertLessThanOrEqual(min(crop.maxY + apron, virtual.height - origin.y),
                                         viewport.renderPixelSize.height, context)
            }
        }
    }

    func testPanBucketReusesTileUntilViewportLeavesIt() throws {
        let standing = try XCTUnwrap(PreviewViewport(
            visibleUnitRect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
            targetPixelSize: CGSize(width: 800, height: 800),
            frameAspect: 1,
            baseLongEdge: 1000))
        let nearby = try XCTUnwrap(PreviewViewport(
            visibleUnitRect: CGRect(x: 0.201, y: 0.201, width: 0.398, height: 0.398),
            targetPixelSize: CGSize(width: 796, height: 796),
            frameAspect: 1,
            baseLongEdge: 1000))
        XCTAssertFalse(standing.isStale(for: nearby))
        for rect in [
            CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.4),
            CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4),
            CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.4),
            CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4)
        ] {
            let outside = try XCTUnwrap(PreviewViewport(
                visibleUnitRect: rect,
                targetPixelSize: CGSize(width: 800, height: 800),
                frameAspect: 1,
                baseLongEdge: 1000))
            XCTAssertTrue(standing.isStale(for: outside))
        }
    }

    func testHigherDensityMakesStandingTileStale() throws {
        let low = try XCTUnwrap(PreviewViewport(
            visibleUnitRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            targetPixelSize: CGSize(width: 500, height: 500),
            frameAspect: 1,
            baseLongEdge: 1000))
        let high = try XCTUnwrap(PreviewViewport(
            visibleUnitRect: low.visibleUnitRect,
            targetPixelSize: CGSize(width: 1000, height: 1000),
            frameAspect: 1,
            baseLongEdge: 1000))
        XCTAssertTrue(low.isStale(for: high))
    }
}
