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
        context.setFillColor(CGColor(colorSpace: space, components: [0.9, 0.1, 0.05, 1])!)
        context.fill(CGRect(x: 13, y: 27, width: 107, height: 89))
        context.setFillColor(CGColor(colorSpace: space, components: [0.07, 0.8, 0.3, 1])!)
        context.fill(CGRect(x: 213, y: 127, width: 47, height: 63))
        return try XCTUnwrap(context.makeImage())
    }

    private func configuration(_ frame: PrintFrame, format: String = "35mm",
                               paper: PrintPaper = .ektacolorEdge,
                               stock: String = "hp5plus400") -> PrintFrameConfiguration {
        PrintFrameConfiguration(frame: frame, formatID: format, stockID: stock, paper: paper)
    }

    func testNoneIsTheOriginalImage() throws {
        let source = try fixture()
        XCTAssertTrue(PrintFrameRenderer.render(source, configuration: configuration(.none)) === source)
    }

    func testEveryFrameAddsSpaceWithoutResizingOrChangingThePhotograph() throws {
        let source = try fixture()
        for frame in PrintFrame.allCases where frame != .none {
            let layout = PrintFrameRenderer.layout(width: source.width, height: source.height, configuration: configuration(frame))
            let result = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: configuration(frame)))
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
            let a = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: configuration(frame)))
            let b = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: configuration(frame)))
            let bytes = try pixels(a)
            XCTAssertEqual(bytes, try pixels(b))
            signatures.insert(bytes)
        }
        XCTAssertEqual(signatures.count, PrintFrame.allCases.count)
    }

    func testPhysicalFilmSizesAndPerforationPatterns() throws {
        let still = try XCTUnwrap(FilmBorderGeometry.preset("35mm"))
        XCTAssertEqual(still.widthMM, 38)
        XCTAssertEqual(still.heightMM, 35)
        XCTAssertEqual(still.apertureWidth, 36)
        XCTAssertEqual(still.apertureHeight, 24)
        XCTAssertEqual(still.perforation, .kodakStandard)
        XCTAssertEqual(still.pitchMM, 4.75)
        XCTAssertEqual(still.rows, 2)
        let respooled = FilmBorderGeometry.preset("35mm", motionPictureStock: true)
        XCTAssertEqual(respooled?.perforation, .bellHowell)
        XCTAssertEqual(respooled?.pitchMM, 4.74)
        let cine = try XCTUnwrap(FilmBorderGeometry.preset("super35"))
        XCTAssertEqual(cine.widthMM, 35)
        XCTAssertEqual(cine.heightMM / cine.pitchMM, 4, accuracy: 0.001)
        XCTAssertEqual(cine.perforation, .bellHowell)
        XCTAssertEqual(FilmBorderGeometry.preset("16mm")?.rows, 1)
        XCTAssertEqual(FilmBorderGeometry.preset("super8")?.rows, 1)
        XCTAssertNil(FilmBorderGeometry.preset("120")?.perforation)
        XCTAssertNil(FilmBorderGeometry.preset("4x5")?.perforation)
    }

    func testCropsFitPhysicalAperturesWithoutStretchingTheFilm() {
        for format in ["35mm", "super35", "16mm", "super8", "120", "4x5"] {
            let config = configuration(.film, format: format)
            for (w, h) in [(200, 300), (300, 200), (1, 1), (300, 300), (500, 100)] {
                let layout = PrintFrameRenderer.layout(width: w, height: h, configuration: config)
                XCTAssertEqual(layout.imageRect.size, CGSize(width: w, height: h))
                XCTAssertTrue(CGRect(origin: .zero, size: layout.size).contains(layout.imageRect))
                let geometry = config.geometry!
                let expectedWidth = layout.rotated ? geometry.heightMM : geometry.widthMM
                let expectedHeight = layout.rotated ? geometry.widthMM : geometry.heightMM
                XCTAssertEqual(layout.size.width / layout.pixelsPerMM, expectedWidth,
                               accuracy: 1 / layout.pixelsPerMM)
                XCTAssertEqual(layout.size.height / layout.pixelsPerMM, expectedHeight,
                               accuracy: 1 / layout.pixelsPerMM)
            }
        }
    }

    func testPaperRequiresARealReflectionPaperAndFollowsItsBaseAndLamp() {
        for paper in [PrintPaper.screen, .negative, .labScan, .telecine, .vision2383, .vision2393, .eternaCP] {
            XCTAssertEqual(configuration(.paper, paper: paper).frame, .none)
        }
        let edge = configuration(.paper)
        let endura = configuration(.paper, paper: .enduraPremier)
        XCTAssertNotEqual(edge.baseRGB, endura.baseRGB)
        let warm = PrintFrameConfiguration(frame: .paper, formatID: "35mm", stockID: "hp5plus400",
                                          paper: .ektacolorEdge, viewingKelvin: 2856)
        XCTAssertNotEqual(edge.baseRGB, warm.baseRGB)
        XCTAssertTrue(edge.detail.contains(PrintPaper.ektacolorEdge.name))
        XCTAssertNil(edge.geometry)
    }

    func testNotchPatternsFollowTheStockOnlyOnSheetFilm() throws {
        let fp4 = configuration(.film, format: "4x5", stock: "fp4plus125")
        let hp5 = configuration(.film, format: "4x5")
        let fp4Code = try XCTUnwrap(fp4.sheetNotches)
        let hp5Code = try XCTUnwrap(hp5.sheetNotches)
        XCTAssertEqual(fp4Code.notches.count, 3)
        XCTAssertEqual(hp5Code.notches.count, 3)
        XCTAssertLessThan(fp4Code.notches[1].position, hp5Code.notches[1].position)
        XCTAssertEqual(fp4Code.notches[0], hp5Code.notches[0])
        XCTAssertEqual(fp4Code.notches[2], hp5Code.notches[2])
        XCTAssertNil(configuration(.film, format: "120").sheetNotches)
        let image = try fixture()
        XCTAssertNotEqual(try pixels(XCTUnwrap(PrintFrameRenderer.render(image, configuration: fp4))),
                          try pixels(XCTUnwrap(PrintFrameRenderer.render(image, configuration: hp5))))
    }

    func testStockNotchMetadataSurvivesCodingAndRejectsInvalidGeometry() throws {
        let definition = try XCTUnwrap(FilmStock.presetDefinitions["hp5plus400"])
        let restored = try JSONDecoder().decode(FilmStockDefinition.self,
                                                from: JSONEncoder().encode(definition))
        XCTAssertEqual(restored.sheetNotches, definition.sheetNotches)
        try restored.validate()
        var invalid = restored
        invalid.sheetNotches?.notches[0].position = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = restored
        invalid.sheetNotches?.notches[1].position = 0
        XCTAssertThrowsError(try invalid.validate())
        invalid = restored
        invalid.sheetNotches?.source = "not-a-source"
        XCTAssertThrowsError(try invalid.validate())
    }

    func testUnsupportedFilmDoesNotInventAGaugeOrNotches() {
        XCTAssertEqual(configuration(.film, format: "unknown").frame, .none)
        XCTAssertEqual(configuration(.film, stock: "no-film").frame, .none)
        XCTAssertEqual(configuration(.film, format: "instaxmini").frame, .none)
        XCTAssertEqual(configuration(.film, format: "35mm", stock: "instaxmini").frame, .none)
        XCTAssertNil(configuration(.film, format: "4x5", stock: "portra400").sheetNotches)
    }

    func testInstantBorderUsesTheActualIntegralFilmDimensions() throws {
        for (id, width) in [("instaxmini", 54.0), ("instaxsquare", 72.0), ("instaxwide", 108.0)] {
            let g = try XCTUnwrap(FilmBorderGeometry.preset(id))
            XCTAssertEqual(g.widthMM, width)
            XCTAssertEqual(g.heightMM, 86)
            XCTAssertNil(g.perforation)
            XCTAssertTrue(g.isInstant)
            let config = configuration(.film, format: id, stock: id)
            XCTAssertEqual(config.frame, FilmStock.presetDefinitions[id] == nil ? .none : .film)
        }
    }

    func testP3AndHLGProfilesAndDepthSurviveFraming() throws {
        for name in [CGColorSpace.displayP3, CGColorSpace.itur_2100_HLG] {
            let space = try XCTUnwrap(CGColorSpace(name: name))
            let source = try fixture(space: space)
            let result = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: configuration(.paper)))
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
