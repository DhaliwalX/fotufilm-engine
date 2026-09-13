#if canImport(CoreGraphics)
import XCTest
import CoreGraphics
import ImageIO
import FotufilmCore
import FotufilmImaging

final class PrintFrameTests: XCTestCase {
    private func fixture(space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200,
            bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.3, 0.5, 0.7, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        return try XCTUnwrap(context.makeImage())
    }

    func testNoneIsTheOriginalImage() throws {
        let source = try fixture()
        XCTAssertTrue(PrintFrameRenderer.render(source, frame: .none) === source)
    }

    func testEveryFrameAddsSpaceWithoutResizingOrChangingThePhotograph() throws {
        let source = try fixture()
        for frame in PrintFrame.allCases where frame != .none {
            let layout = PrintFrameRenderer.layout(width: source.width, height: source.height, frame: frame)
            let result = try XCTUnwrap(PrintFrameRenderer.render(source, frame: frame))
            XCTAssertEqual(result.width, Int(layout.size.width))
            XCTAssertEqual(result.height, Int(layout.size.height))
            XCTAssertGreaterThan(result.width, source.width)
            XCTAssertGreaterThan(result.height, source.height)
            XCTAssertEqual(layout.imageRect.size, CGSize(width: source.width, height: source.height))
            XCTAssertEqual(result.bitsPerComponent, 16)
            XCTAssertEqual(result.colorSpace, source.colorSpace)
            // CGImage cropping uses top-left coordinates; the layout uses bottom-left.
            let crop = CGRect(x: layout.imageRect.minX,
                              y: layout.size.height - layout.imageRect.maxY,
                              width: CGFloat(source.width), height: CGFloat(source.height))
            let centre = try XCTUnwrap(result.cropping(to: crop))
            XCTAssertEqual(try pixels(centre), try pixels(source), "\(frame) changed the photograph")
        }
    }

    func testTextureIsRepeatableAndStylesAreDistinct() throws {
        let source = try fixture()
        var signatures = Set<Data>()
        for frame in PrintFrame.allCases {
            let a = try XCTUnwrap(PrintFrameRenderer.render(source, frame: frame))
            let b = try XCTUnwrap(PrintFrameRenderer.render(source, frame: frame))
            let bytes = try pixels(a)
            XCTAssertEqual(bytes, try pixels(b))
            signatures.insert(bytes)
        }
        XCTAssertEqual(signatures.count, PrintFrame.allCases.count)
    }

    func testPortraitLandscapeAndTinyLayoutsKeepInstantMarginAtTheBottom() {
        for (w, h) in [(200, 300), (300, 200), (1, 1), (300, 300)] {
            let layout = PrintFrameRenderer.layout(width: w, height: h, frame: .instant)
            XCTAssertEqual(layout.imageRect.size, CGSize(width: w, height: h))
            XCTAssertGreaterThanOrEqual(layout.imageRect.minY,
                                        layout.size.height - layout.imageRect.maxY)
        }
    }

    func testP3AndHLGProfilesAndDepthSurviveFraming() throws {
        for name in [CGColorSpace.displayP3, CGColorSpace.itur_2100_HLG] {
            let space = try XCTUnwrap(CGColorSpace(name: name))
            let source = try fixture(space: space)
            let result = try XCTUnwrap(PrintFrameRenderer.render(source, frame: .baryta))
            XCTAssertEqual(result.colorSpace, space)
            XCTAssertEqual(result.bitsPerComponent, 16)
        }
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 16, bytesPerRow: image.width * 8, space: image.colorSpace!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 8)
    }
}
#endif
