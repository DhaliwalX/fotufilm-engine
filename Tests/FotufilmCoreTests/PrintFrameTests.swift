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

    /// A film and medium on which the frame is available.
    private func representative(_ frame: PrintFrame) -> PrintFrameConfiguration {
        configuration(frame, stock: frame == .slideMount ? "velvia50" : "hp5plus400")
    }

    /// The photograph's crop in top-left image coordinates, inset by the rim the emulsion band may
    /// bleed into; every other frame leaves the whole photograph untouched.
    private func untouched(_ frame: PrintFrame, layout: PrintFrameRenderer.Layout,
                           width: Int, height: Int) -> CGRect {
        let crop = CGRect(x: layout.imageRect.minX, y: layout.size.height - layout.imageRect.maxY,
                          width: CGFloat(width), height: CGFloat(height))
        let rim = frame == .emulsion ? ceil(CGFloat(min(width, height)) * PrintFrameRenderer.emulsionRim) : 0
        return crop.insetBy(dx: rim, dy: rim)
    }

    private func rgb(_ image: CGImage, _ data: Data, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let offset = (y * image.width + x) * 8
        return SIMD3((0..<3).map { channel in
            let i = offset + channel * 2
            return Float(UInt16(data[i]) | UInt16(data[i + 1]) << 8) / 65535
        })
    }

    func testNoneIsTheOriginalImage() throws {
        let source = try fixture()
        XCTAssertTrue(PrintFrameRenderer.render(source, configuration: configuration(.none)) === source)
    }

    func testEveryFrameAddsSpaceWithoutResizingOrChangingThePhotograph() throws {
        let source = try fixture()
        for frame in PrintFrame.allCases where frame != .none {
            let config = representative(frame)
            XCTAssertEqual(config.frame, frame)
            let layout = PrintFrameRenderer.layout(width: source.width, height: source.height, configuration: config)
            let result = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: config))
            XCTAssertEqual(result.width, Int(layout.size.width))
            XCTAssertEqual(result.height, Int(layout.size.height))
            XCTAssertGreaterThan(result.width, source.width)
            XCTAssertGreaterThan(result.height, source.height)
            XCTAssertEqual(layout.imageRect.size, CGSize(width: source.width, height: source.height))
            XCTAssertEqual(result.bitsPerComponent, 16)
            XCTAssertEqual(result.colorSpace, source.colorSpace)
            // CGImage cropping uses top-left coordinates; the layout uses bottom-left.
            let crop = untouched(frame, layout: layout, width: source.width, height: source.height)
            let centre = try XCTUnwrap(result.cropping(to: crop))
            let inner = CGRect(x: crop.minX - layout.imageRect.minX,
                               y: crop.minY - (layout.size.height - layout.imageRect.maxY),
                               width: crop.width, height: crop.height)
            XCTAssertEqual(try pixels(centre), try pixels(XCTUnwrap(source.cropping(to: inner))),
                           "\(frame) changed the photograph")
        }
    }

    func testTextureIsRepeatableAndStylesAreDistinct() throws {
        let source = try fixture()
        var signatures = Set<Data>()
        for frame in PrintFrame.allCases {
            let a = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: representative(frame)))
            let b = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: representative(frame)))
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
        let warm = PrintFrameConfiguration(frame: .paper, formatID: "35mm", stockID: "hp5plus400",
                                          paper: .ektacolorEdge, viewingKelvin: 2856)
        // Clear paper is the print's own white, under whatever lamp the print is read by — the
        // same white the photograph's highlights reach.
        for base in [edge.baseRGB, endura.baseRGB, warm.baseRGB] {
            for channel in 0..<3 { XCTAssertEqual(base[channel], 1, accuracy: 1e-4) }
        }
        // The dye a fully exposed rebate carries is the paper's own and meets the lamp.
        func rebate(_ paper: PrintPaper, _ kelvin: Float?) -> SIMD3<Float> {
            PrintFrameConfiguration(frame: .carrier, formatID: "35mm", stockID: "hp5plus400",
                                    paper: paper, viewingKelvin: kelvin).rebateRGB
        }
        XCTAssertNotEqual(rebate(.ektacolorEdge, nil), rebate(.enduraPremier, nil))
        XCTAssertNotEqual(rebate(.ektacolorEdge, nil), rebate(.ektacolorEdge, 2856))
        XCTAssertTrue(edge.detail.contains(PrintPaper.ektacolorEdge.name))
        XCTAssertNil(edge.geometry)
    }

    func testEmulsionKeepsTheCropAndIsAvailableWithoutFilmOrReflectionPaper() throws {
        for (w, h) in [(200, 300), (300, 200), (200, 200), (1000, 1)] {
            for format in ["35mm", "120", "4x5", "unknown"] {
                let config = configuration(.emulsion, format: format, paper: .screen, stock: "original")
                XCTAssertEqual(config.frame, .emulsion)
                XCTAssertNil(config.geometry)
                XCTAssertNil(config.sheetNotches)
                XCTAssertNil(config.edgePrinting)
                let layout = PrintFrameRenderer.layout(width: w, height: h, configuration: config)
                XCTAssertEqual(layout.imageRect.size, CGSize(width: w, height: h))
                let x = ceil(Double(min(w, h)) * 0.095), y = ceil(Double(min(w, h)) * 0.135)
                XCTAssertEqual(layout.imageRect.minX, x)
                XCTAssertEqual(layout.imageRect.minY, y)
                XCTAssertEqual(layout.size, CGSize(width: Double(w) + 2 * x, height: Double(h) + 2 * y))
            }
        }
        // An extreme panorama must not allocate a texture proportional to its aspect ratio.
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 1, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let framed = try XCTUnwrap(PrintFrameRenderer.render(XCTUnwrap(context.makeImage()),
            configuration: configuration(.emulsion)))
        XCTAssertEqual(framed.width, 1002)
        XCTAssertEqual(framed.height, 3)
    }

    func testEmulsionMountUsesPaperWhiteAndPreservesItsViewingLight() {
        for paper in [PrintPaper.ektacolorEdge, .enduraPremier, .crystalArchive] {
            for kelvin in [Float(2856), 5000, 6500] {
                let emulsion = PrintFrameConfiguration(frame: .emulsion, formatID: nil,
                    stockID: "original", paper: paper, viewingKelvin: kelvin)
                let sheet = PrintFrameConfiguration(frame: .paper, formatID: nil,
                    stockID: "original", paper: paper, viewingKelvin: kelvin)
                XCTAssertEqual(emulsion.frame, .emulsion)
                XCTAssertEqual(emulsion.baseRGB, sheet.baseRGB)
            }
        }
        for paper in [PrintPaper.screen, .negative, .labScan, .vision2383] {
            let config = configuration(.emulsion, paper: paper)
            XCTAssertEqual(config.frame, .emulsion)
            XCTAssertEqual(config.baseRGB, SIMD3(repeating: 0.91))
        }
    }

    func testEmulsionHasADarkBandWornOuterEdgeAndCleanMount() throws {
        let source = try fixture()
        let config = configuration(.emulsion, paper: .screen)
        let result = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: config))
        let data = try pixels(result)
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let offset = (y * result.width + x) * 8
            return SIMD3((0..<3).map { channel in
                let i = offset + channel * 2
                return Float(UInt16(data[i]) | UInt16(data[i + 1]) << 8) / 65535
            })
        }
        let white = rgb(0, 0)
        for point in [(3, 100), (result.width - 3, 100), (150, 3), (150, result.height - 3)] {
            XCTAssertEqual(rgb(point.0, point.1), white, "Outer paper should remain clean")
        }
        let band = rgb(17, 100)
        XCTAssertLessThan(max(band.x, band.y, band.z), 0.15)
        let fringe = (50..<150).map { rgb(12, $0).x }
        XCTAssertGreaterThan(fringe.max()! - fringe.min()!, 0.08, "The edge should have varying coverage")
        let otherGauge = configuration(.emulsion, format: "4x5", paper: .screen, stock: "portra400")
        XCTAssertEqual(data, try pixels(XCTUnwrap(PrintFrameRenderer.render(source, configuration: otherGauge))))
    }

    func testEmulsionBandFadesIntoThePhotographWithAnUnevenEdge() throws {
        let source = try fixture()
        let config = configuration(.emulsion, paper: .screen)
        let layout = PrintFrameRenderer.layout(width: source.width, height: source.height, configuration: config)
        let result = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: config))
        let data = try pixels(result)
        let original = try pixels(source)
        let left = Int(layout.imageRect.minX), top = Int(layout.size.height - layout.imageRect.maxY)
        let rim = Int(ceil(Double(min(source.width, source.height)) * Double(PrintFrameRenderer.emulsionRim)))
        // The picture's own edge is under the band: darker than the source, and not a cut line.
        var depth = [Int]()
        for x in stride(from: 20, to: source.width - 20, by: 4) {
            var run = 0
            while run < rim, rgb(result, data, left + x, top + run).y < rgb(source, original, x, run).y * 0.5 { run += 1 }
            depth.append(run)
        }
        XCTAssertGreaterThan(depth.min()!, 0, "the band should cover the photograph's edge")
        XCTAssertGreaterThan(depth.max()! - depth.min()!, 2, "the inner edge should be uneven")
        XCTAssertLessThan(depth.max()!, rim, "the band must stop within the rim")
        // Halfway through the rim the picture shows through; past the rim it is untouched.
        let mid = rgb(result, data, left + source.width / 2, top + rim / 2)
        XCTAssertGreaterThan(mid.y, 0.05)
        XCTAssertLessThan(mid.y, rgb(source, original, source.width / 2, rim / 2).y)
        XCTAssertEqual(rgb(result, data, left + source.width / 2, top + rim + 2),
                       rgb(source, original, source.width / 2, rim + 2))
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

    func testFilmBorderColourFollowsTheStocksOwnBaseAndReversalDensity() throws {
        let portra = configuration(.film, stock: "portra400")
        let gold = configuration(.film, stock: "gold200")
        let monochrome = configuration(.film, stock: "hp5plus400")
        let reversal = configuration(.film, stock: "ektachromee100")
        XCTAssertNotEqual(portra.baseRGB, gold.baseRGB)
        XCTAssertNotEqual(portra.baseRGB, monochrome.baseRGB)
        XCTAssertGreaterThan(portra.baseRGB.x, portra.baseRGB.z)
        XCTAssertGreaterThan(monochrome.baseRGB.x, reversal.baseRGB.x)
        XCTAssertLessThan(reversal.baseRGB.x, 0.05)
        XCTAssertEqual(max(portra.baseRGB.x, portra.baseRGB.y, portra.baseRGB.z),
                       SpectralRuntime.lightBoxBaseLevel, accuracy: 0.00001)
        let warm = PrintFrameConfiguration(frame: .film, formatID: "35mm", stockID: "portra400",
                                           paper: .ektacolorEdge, viewingKelvin: 2856)
        XCTAssertNotEqual(warm.baseRGB, portra.baseRGB)
        let scanner = PrintFrameConfiguration(frame: .film, formatID: "35mm", stockID: "portra400",
                                              paper: .negative, negativeViewing: .scanner)
        XCTAssertEqual(scanner.baseRGB, SIMD3(repeating: 1))
        let image = try fixture()
        XCTAssertNotEqual(try pixels(XCTUnwrap(PrintFrameRenderer.render(image, configuration: portra))),
                          try pixels(XCTUnwrap(PrintFrameRenderer.render(image, configuration: gold))))
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

    func testEdgeInscriptionsFollowStockAndGaugeWithoutInventingOtherMaterials() throws {
        XCTAssertEqual(configuration(.film, stock: "portra400").edgePrinting?.marks.first?.text,
                       "KODAK PORTRA 400")
        XCTAssertEqual(configuration(.film).edgePrinting?.marks.first?.text, "ILFORD HP5 PLUS")
        XCTAssertEqual(configuration(.film, stock: "velvia50").edgePrinting?.marks.first?.text, "FUJI RVP50")
        for (stock, code, prefix) in [("vision500t", "5219", "EJ"), ("vision250d", "5207", "EN")] {
            XCTAssertEqual(configuration(.film, format: "super35", stock: stock).edgePrinting?.marks.first?.text, code)
            XCTAssertEqual(configuration(.film, format: "16mm", stock: stock).edgePrinting?.marks.first?.text, prefix)
            XCTAssertNil(configuration(.film, format: "120", stock: stock).edgePrinting)
        }
        XCTAssertNil(configuration(.film, format: "4x5", stock: "portra400").edgePrinting)
        XCTAssertNil(configuration(.film, format: "super8", stock: "vision500t").edgePrinting)
        XCTAssertNil(configuration(.film, stock: "no-film").edgePrinting)
        XCTAssertNil(configuration(.paper, stock: "portra400").edgePrinting)
        XCTAssertNil(configuration(.none, stock: "portra400").edgePrinting)
        XCTAssertNil(configuration(.film, format: "instaxmini", stock: "instaxmini").edgePrinting)
    }

    func testEdgeExposureUsesNegativeAndReversalDensityWithTheSameViewingLamp() {
        for id in ["portra400", "hp5plus400", "vision500t"] {
            let config = configuration(.film, stock: id)
            XCTAssertLessThan(config.edgeRGB.x, config.baseRGB.x)
            XCTAssertLessThan(config.edgeRGB.y, config.baseRGB.y)
            XCTAssertLessThan(config.edgeRGB.z, config.baseRGB.z)
        }
        let reversal = configuration(.film, stock: "velvia50")
        XCTAssertGreaterThan(reversal.edgeRGB.x, reversal.baseRGB.x)
        XCTAssertGreaterThan(reversal.edgeRGB.y, reversal.baseRGB.y)
        XCTAssertGreaterThan(reversal.edgeRGB.z, reversal.baseRGB.z)
        let warm = PrintFrameConfiguration(frame: .film, formatID: "35mm", stockID: "portra400",
                                           paper: .negative, viewingKelvin: 2856)
        XCTAssertNotEqual(warm.edgeRGB, configuration(.film, stock: "portra400").edgeRGB)
    }

    func testEdgeMetadataRoundTripsAndRejectsUnprintableGeometry() throws {
        let definition = try XCTUnwrap(FilmStock.presetDefinitions["portra400"])
        let restored = try JSONDecoder().decode(FilmStockDefinition.self,
                                                from: JSONEncoder().encode(definition))
        XCTAssertEqual(restored.edgePrinting, definition.edgePrinting)
        try restored.validate()
        var invalid = restored
        invalid.edgePrinting?[0].marks[0].xMM = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = restored
        invalid.edgePrinting?[0].marks[0].yMM = 10 // photograph aperture
        XCTAssertThrowsError(try invalid.validate())
        invalid = restored
        invalid.edgePrinting?[0].marks[0].yMM = 3 // perforations
        XCTAssertThrowsError(try invalid.validate())
        invalid = restored
        invalid.edgePrinting?[0].sources = ["not-a-source"]
        XCTAssertThrowsError(try invalid.validate())
        invalid = restored
        invalid.edgePrinting?[0].formatID = "instaxmini"
        XCTAssertThrowsError(try invalid.validate())
        invalid = restored
        invalid.edgePrinting?.append(restored.edgePrinting![0])
        XCTAssertThrowsError(try invalid.validate())
        // Old packs still decode and validate without markings.
        invalid = restored
        invalid.edgePrinting = nil
        let old = try JSONDecoder().decode(FilmStockDefinition.self, from: JSONEncoder().encode(invalid))
        XCTAssertNil(old.edgePrinting)
        try old.validate()
    }

    func testLetteringIsVisibleInItsPhysicalBoxForBothImageOrientations() throws {
        let source = try fixture()
        for id in ["portra400", "hp5plus400", "velvia50", "vision500t"] {
            let definition = try XCTUnwrap(FilmStock.presetDefinitions[id])
            for printing in try XCTUnwrap(definition.edgePrinting) {
                try definition.validate()
                for portrait in [false, true] {
                    let photo = portrait ? try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 100, height: 200))) : source
                    let config = configuration(.film, format: printing.formatID, stock: id)
                    let g = try XCTUnwrap(config.geometry)
                    let layout = PrintFrameRenderer.layout(width: photo.width, height: photo.height, configuration: config)
                    let result = try XCTUnwrap(PrintFrameRenderer.render(photo, configuration: config))
                    for mark in printing.marks {
                        var box = CGRect(x: mark.xMM, y: mark.yMM, width: mark.widthMM, height: mark.heightMM)
                        if !g.horizontalTransport {
                            box = CGRect(x: g.widthMM - box.maxY, y: box.minX, width: box.height, height: box.width)
                        }
                        if layout.rotated {
                            box = CGRect(x: g.heightMM - box.maxY, y: box.minX, width: box.height, height: box.width)
                        }
                        box = box.applying(CGAffineTransform(scaleX: layout.pixelsPerMM, y: layout.pixelsPerMM))
                        box.origin.y = layout.size.height - box.maxY
                        let patch = try XCTUnwrap(result.cropping(to: box.integral))
                        let bytes = try pixels(patch)
                        let colours = Set(stride(from: 0, to: bytes.count, by: 8).map { bytes.subdata(in: $0..<($0 + 8)) })
                        XCTAssertGreaterThan(colours.count, 2, "Missing \(id) \(printing.formatID) \(mark.text), portrait=\(portrait)")
                    }
                    let crop = CGRect(x: layout.imageRect.minX, y: layout.size.height - layout.imageRect.maxY,
                                      width: CGFloat(photo.width), height: CGFloat(photo.height))
                    XCTAssertEqual(try pixels(XCTUnwrap(result.cropping(to: crop))), try pixels(photo))
                }
            }
        }
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
            for frame in [PrintFrame.paper, .emulsion] {
                let result = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: configuration(frame)))
                XCTAssertEqual(result.colorSpace, space)
                XCTAssertEqual(result.bitsPerComponent, 16)
                let layout = PrintFrameRenderer.layout(width: source.width, height: source.height, configuration: configuration(frame))
                let crop = untouched(frame, layout: layout, width: source.width, height: source.height)
                let inner = CGRect(x: crop.minX - layout.imageRect.minX,
                                   y: crop.minY - (layout.size.height - layout.imageRect.maxY),
                                   width: crop.width, height: crop.height)
                XCTAssertEqual(try pixels(XCTUnwrap(result.cropping(to: crop))),
                               try pixels(XCTUnwrap(source.cropping(to: inner))))
            }
        }
    }

    func testPlainMountsFollowTheCropOnEveryOutput() throws {
        for frame in [PrintFrame.mount, .darkMount] {
            for paper in [PrintPaper.screen, .negative, .labScan, .vision2383, .ektacolorEdge, .ilfochromeCPS1K] {
                for stock in ["original", "portra400", "velvia50"] {
                    let config = configuration(frame, format: "unknown", paper: paper, stock: stock)
                    XCTAssertEqual(config.frame, frame)
                    XCTAssertNil(config.geometry)
                    XCTAssertNil(config.sheet)
                    XCTAssertNil(config.slideMount)
                    for (w, h) in [(200, 300), (300, 200), (200, 200), (1000, 1)] {
                        let layout = PrintFrameRenderer.layout(width: w, height: h, configuration: config)
                        let margin = ceil(Double(min(w, h)) * 0.08)
                        XCTAssertEqual(layout.imageRect, CGRect(x: margin, y: margin, width: Double(w), height: Double(h)))
                        XCTAssertEqual(layout.size, CGSize(width: Double(w) + 2 * margin, height: Double(h) + 2 * margin))
                    }
                }
            }
        }
        // The white mount is the selected paper's own base where there is one; the black
        // mount is a neutral presentation board everywhere.
        let sheet = configuration(.paper)
        XCTAssertEqual(configuration(.mount).baseRGB, sheet.baseRGB)
        XCTAssertEqual(configuration(.mount, paper: .screen).baseRGB, SIMD3(repeating: 0.91))
        XCTAssertEqual(configuration(.darkMount).baseRGB, SIMD3(repeating: 0.02))
        XCTAssertEqual(configuration(.darkMount, paper: .screen).baseRGB, SIMD3(repeating: 0.02))
        let source = try fixture()
        for frame in [PrintFrame.mount, .darkMount] {
            let result = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: configuration(frame, paper: .screen)))
            let data = try pixels(result)
            let corner = rgb(result, data, 0, 0)
            for point in [(result.width - 1, 0), (0, result.height - 1), (result.width / 2, 2), (2, result.height / 2)] {
                XCTAssertEqual(rgb(result, data, point.0, point.1), corner, "\(frame) mount is not uniform")
            }
            XCTAssertEqual(corner.x > 0.5, frame == .mount)
        }
    }

    func testPaperSizesAreRealSheetsOnTheSameEasel() throws {
        let expected: [(PrintFrame, Double, Double)] = [
            (.paper, 152.4, 101.6), (.paper5x7, 177.8, 127), (.paper8x10, 254, 203.2), (.paper5x5, 127, 127)]
        for (frame, width, height) in expected {
            let config = configuration(frame)
            XCTAssertEqual(config.frame, frame)
            let sheet = try XCTUnwrap(config.sheet)
            XCTAssertEqual(sheet.widthMM, width)
            XCTAssertEqual(sheet.heightMM, height)
            XCTAssertEqual(sheet.marginMM, 3)
            XCTAssertEqual(sheet.rebateMM, 0)
            XCTAssertNil(config.geometry)
            XCTAssertEqual(config.baseRGB, configuration(.paper).baseRGB)
            XCTAssertTrue(config.detail.contains(PrintPaper.ektacolorEdge.name))
            for (w, h) in [(300, 200), (200, 300), (300, 300)] {
                let layout = PrintFrameRenderer.layout(width: w, height: h, configuration: config)
                let rotated = layout.rotated
                XCTAssertEqual(layout.size.width / layout.pixelsPerMM, rotated ? height : width,
                               accuracy: 1 / layout.pixelsPerMM)
                XCTAssertEqual(layout.size.height / layout.pixelsPerMM, rotated ? width : height,
                               accuracy: 1 / layout.pixelsPerMM)
                XCTAssertTrue(CGRect(origin: .zero, size: layout.size).contains(layout.imageRect))
            }
            for paper in [PrintPaper.screen, .negative, .labScan, .telecine, .vision2383] {
                XCTAssertEqual(configuration(frame, paper: paper).frame, .none)
            }
        }
        // A square sheet never rotates; a 3 × 2 crop leaves paper above and below it.
        let square = PrintFrameRenderer.layout(width: 300, height: 200, configuration: configuration(.paper5x5))
        XCTAssertFalse(square.rotated)
        XCTAssertEqual(square.size.width, square.size.height)
        XCTAssertGreaterThan(square.imageRect.minY, square.imageRect.minX)
    }

    func testCarrierPrintsTheNegativeRebateInsideTheEaselMargin() throws {
        for stock in ["hp5plus400", "portra400", "vision500t"] {
            let config = configuration(.carrier, stock: stock)
            XCTAssertEqual(config.frame, .carrier, stock)
            let sheet = try XCTUnwrap(config.sheet)
            XCTAssertEqual(sheet.widthMM, 254)
            XCTAssertEqual(sheet.heightMM, 203.2)
            XCTAssertEqual(sheet.marginMM, 12.7)
            XCTAssertEqual(sheet.rebateMM, 2.5)
            XCTAssertLessThan(config.rebateRGB.x, config.baseRGB.x * 0.2)
            XCTAssertLessThan(config.rebateRGB.y, config.baseRGB.y * 0.2)
            XCTAssertLessThan(config.rebateRGB.z, config.baseRGB.z * 0.2)
        }
        XCTAssertEqual(configuration(.carrier, stock: "velvia50").frame, .none)
        XCTAssertEqual(configuration(.carrier, stock: "no-film").frame, .none)
        XCTAssertEqual(configuration(.carrier, stock: "original").frame, .none)
        XCTAssertEqual(configuration(.carrier, paper: .ilfochromeCPS1K).frame, .none)
        XCTAssertEqual(configuration(.carrier, paper: .screen).frame, .none)
        XCTAssertEqual(configuration(.carrier, paper: .negative).frame, .none)
        XCTAssertEqual(configuration(.carrier, format: "instaxmini", stock: "instaxmini").frame, .none)
        XCTAssertNotEqual(configuration(.carrier).rebateRGB, configuration(.carrier, paper: .enduraPremier).rebateRGB)
        XCTAssertEqual(configuration(.paper).rebateRGB, .zero)

        // Enlarge the fixture so the 8 × 10 sheet renders at about 4 px/mm.
        let source = try enlarged(fixture(), by: 3)
        let config = configuration(.carrier)
        let layout = PrintFrameRenderer.layout(width: source.width, height: source.height, configuration: config)
        let result = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: config))
        let data = try pixels(result)
        let white = rgb(result, data, 0, 0)
        XCTAssertGreaterThan(white.y, 0.6)
        // The printed rebate wraps the photograph; the easel margin beyond it stays paper white.
        let rebate = Int((1.25 * layout.pixelsPerMM).rounded())
        let top = Int(layout.size.height - layout.imageRect.maxY)
        let left = Int(layout.imageRect.minX)
        // Pixel values are read in the fixture's encoded sRGB, as in the emulsion test.
        let inside = rgb(result, data, left - rebate, top + source.height / 2)
        XCTAssertLessThan(max(inside.x, inside.y, inside.z), 0.15)
        let above = rgb(result, data, left + source.width / 2, top - rebate)
        XCTAssertLessThan(max(above.x, above.y, above.z), 0.15)
        let margin = rgb(result, data, left - Int(6 * layout.pixelsPerMM), top + source.height / 2)
        XCTAssertGreaterThan(min(margin.x, margin.y, margin.z), 0.8, "the easel margin beyond the rebate is paper")
        // The filed outer edge is uneven; the inner edge follows the photograph exactly.
        let outerEdge = (0..<source.width).map { x -> Float in
            let column = left + x
            var run = 0
            while rgb(result, data, column, top - 1 - run).x < 0.15 { run += 1 }
            return Float(run)
        }
        XCTAssertGreaterThan(outerEdge.max()! - outerEdge.min()!, 0.5)
        let crop = CGRect(x: layout.imageRect.minX, y: layout.size.height - layout.imageRect.maxY,
                          width: CGFloat(source.width), height: CGFloat(source.height))
        XCTAssertEqual(try pixels(XCTUnwrap(result.cropping(to: crop))), try pixels(source))
    }

    func testSlideMountHoldsAReversalTransparencyInADocumentedAperture() throws {
        let mounted = configuration(.slideMount, stock: "velvia50")
        XCTAssertEqual(mounted.frame, .slideMount)
        let mount = try XCTUnwrap(mounted.slideMount)
        XCTAssertEqual(mount.mountMM, 50.8)
        XCTAssertEqual(mount.apertureWidth, 34.5)
        XCTAssertEqual(mount.apertureHeight, 23)
        XCTAssertNil(mounted.geometry)
        XCTAssertNil(mounted.sheet)
        XCTAssertTrue(mounted.detail.contains("2 × 2 in"))
        let medium = try XCTUnwrap(configuration(.slideMount, format: "120", stock: "velvia50").slideMount)
        XCTAssertEqual(medium.mountMM, 70)
        XCTAssertEqual(medium.apertureWidth, 56)
        XCTAssertEqual(medium.apertureHeight, 56)
        for (format, stock) in [("35mm", "portra400"), ("35mm", "hp5plus400"), ("super35", "velvia50"),
                                ("4x5", "velvia50"), ("instaxmini", "instaxmini"), ("35mm", "no-film")] {
            XCTAssertEqual(configuration(.slideMount, format: format, stock: stock).frame, .none, "\(format) \(stock)")
        }
        // The transparency is viewed through the mount regardless of the chosen paper.
        for paper in [PrintPaper.screen, .negative, .ektacolorEdge, .ilfochromeCPS1K, .vision2383] {
            XCTAssertEqual(configuration(.slideMount, paper: paper, stock: "velvia50").frame, .slideMount)
        }
        // The rebate visible around a nonmatching crop is the stock's own maximum density.
        XCTAssertEqual(mounted.baseRGB, configuration(.film, stock: "velvia50").baseRGB)
        XCTAssertNotEqual(mounted.baseRGB, configuration(.slideMount, stock: "ektachromee100").baseRGB)

        let source = try fixture()
        for (w, h) in [(300, 200), (200, 300), (200, 200)] {
            let layout = PrintFrameRenderer.layout(width: w, height: h, configuration: mounted)
            XCTAssertEqual(layout.size.width, layout.size.height)
            XCTAssertEqual(layout.size.width / layout.pixelsPerMM, 50.8, accuracy: 1 / layout.pixelsPerMM)
            XCTAssertEqual(layout.rotated, h >= w, "a square crop turns with the landscape aperture, as on film")
        }
        // A square crop leaves the 3 : 2 aperture open on both sides of the photograph.
        let square = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 200)))
        let layout = PrintFrameRenderer.layout(width: square.width, height: square.height, configuration: mounted)
        let result = try XCTUnwrap(PrintFrameRenderer.render(square, configuration: mounted))
        let data = try pixels(result)
        let card = rgb(result, data, 0, 0)
        XCTAssertGreaterThan(card.y, 0.6)
        XCTAssertEqual(rgb(result, data, result.width - 1, result.height - 1), card)
        XCTAssertEqual(rgb(result, data, result.width / 2, 2), card)
        // The square crop turns with the 3 : 2 aperture, so dark rebate shows above and below it.
        XCTAssertTrue(layout.rotated)
        let top = Int(layout.size.height - layout.imageRect.maxY)
        let rebate = rgb(result, data, Int(layout.imageRect.minX) + square.width / 2, top - 2)
        XCTAssertLessThan(max(rebate.x, rebate.y, rebate.z), 0.1)
        let crop = CGRect(x: layout.imageRect.minX, y: layout.size.height - layout.imageRect.maxY,
                          width: CGFloat(square.width), height: CGFloat(square.height))
        XCTAssertEqual(try pixels(XCTUnwrap(result.cropping(to: crop))), try pixels(square))
    }

    func testSocialCanvasesHoldTheirAspectAndMarginOnEveryOutput() throws {
        let expected: [(PrintFrame, Double)] = [(.socialSquare, 1), (.socialPortrait, 0.8), (.socialStory, 9.0 / 16)]
        for (frame, aspect) in expected {
            for paper in [PrintPaper.screen, .negative, .labScan, .ektacolorEdge, .ilfochromeCPS1K, .vision2383] {
                for stock in ["original", "portra400", "velvia50"] {
                    let config = configuration(frame, format: "unknown", paper: paper, stock: stock)
                    XCTAssertEqual(config.frame, frame)
                    XCTAssertEqual(config.baseRGB, SIMD3(repeating: 1), "a post's margin is display white")
                    let canvas = try XCTUnwrap(config.canvas)
                    for (w, h) in [(300, 200), (200, 300), (200, 200), (1000, 1), (1, 1000)] {
                        let layout = PrintFrameRenderer.layout(width: w, height: h, configuration: config)
                        XCTAssertFalse(layout.rotated)
                        XCTAssertEqual(layout.size.width / layout.size.height, aspect, accuracy: 0.01,
                                       "\(frame) \(w)x\(h)")
                        let short = min(layout.size.width, layout.size.height)
                        let margin = short * canvas.margin - 1
                        XCTAssertGreaterThanOrEqual(layout.imageRect.minX, margin)
                        XCTAssertGreaterThanOrEqual(layout.imageRect.minY, margin)
                        XCTAssertGreaterThanOrEqual(layout.size.width - layout.imageRect.maxX, margin)
                        XCTAssertGreaterThanOrEqual(layout.size.height - layout.imageRect.maxY, margin)
                        // The photograph binds on one side: the canvas is no larger than it must be.
                        let slackX = layout.size.width - 2 * short * canvas.margin - CGFloat(w)
                        let slackY = layout.size.height - 2 * short * canvas.margin - CGFloat(h)
                        XCTAssertLessThan(min(slackX, slackY), 2)
                        XCTAssertEqual(layout.imageRect.midX, layout.size.width / 2, accuracy: 1)
                        XCTAssertEqual(layout.imageRect.midY, layout.size.height / 2, accuracy: 1)
                    }
                }
            }
        }
        let source = try fixture()
        let result = try XCTUnwrap(PrintFrameRenderer.render(source, configuration: configuration(.socialStory, paper: .screen)))
        let data = try pixels(result)
        let corner = rgb(result, data, 0, 0)
        XCTAssertGreaterThan(corner.y, 0.95)
        XCTAssertEqual(rgb(result, data, result.width / 2, 2), corner)
    }

    func testNewFramesRoundTripAndOldNamesStillDecode() throws {
        for frame in PrintFrame.allCases {
            let data = try JSONEncoder().encode([frame])
            XCTAssertEqual(try JSONDecoder().decode([PrintFrame].self, from: data), [frame])
        }
        XCTAssertEqual(try JSONDecoder().decode([PrintFrame].self, from: Data("[\"contact\"]".utf8)), [.paper])
        XCTAssertThrowsError(try JSONDecoder().decode([PrintFrame].self, from: Data("[\"polaroid\"]".utf8)))
    }

    private func enlarged(_ image: CGImage, by factor: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width * factor, height: image.height * factor,
            bitsPerComponent: 16, bytesPerRow: 0, space: image.colorSpace!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * factor, height: image.height * factor))
        return try XCTUnwrap(context.makeImage())
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
