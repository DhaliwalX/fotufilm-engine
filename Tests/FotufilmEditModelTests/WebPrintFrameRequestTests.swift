import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebPrintFrameRequestTests: XCTestCase {
    private func request(_ frame: PrintFrame, stock: String? = "gold200", format: String = "35mm",
                         medium: String = "ektacolor-edge", width: Int = 300, height: Int = 200,
                         margin: Double? = nil) throws -> Data {
        var value: [String: Any] = ["kind": "print-frame", "frame": frame.rawValue,
            "format": format, "medium": medium, "width": width, "height": height]
        if let margin { value["margin"] = margin }
        if let stock {
            value["stock"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
                XCTUnwrap(FilmStock.presetDefinitions[stock])))
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func result(_ data: Data) throws -> WebPrintFrameRequest.Result {
        try JSONDecoder().decode(WebPrintFrameRequest.Result.self, from: WebRenderRequest.prepare(data))
    }

    func testEveryFrameUsesNativePhysicalMaterialAndOrientation() throws {
        for frame in PrintFrame.allCases where frame != .emulsion {
            let stock = frame == .slideMount ? "ektachromee100" : "gold200"
            let paper = frame == .slideMount ? "ilfochrome-cps-1k" : "ektacolor-edge"
            for size in [(300, 200), (200, 300), (100, 100)] {
                let actual = try result(request(frame, stock: stock, medium: paper, width: size.0, height: size.1))
                let expected = PrintFrameConfiguration(frame: frame, formatID: "35mm", stockID: stock,
                                                       paper: PrintPaper.preset(id: paper)!)
                XCTAssertEqual(actual.configuration, expected)
                XCTAssertEqual(actual.placement, PrintFramePlacement.layout(width: size.0, height: size.1, configuration: expected))
                XCTAssertTrue(actual.available.contains(frame))
                XCTAssertEqual(actual.placement.image.width, Double(size.0))
                XCTAssertEqual(actual.placement.image.height, Double(size.1))
                XCTAssertGreaterThanOrEqual(actual.placement.size.width, Double(size.0))
                XCTAssertGreaterThanOrEqual(actual.placement.size.height, Double(size.1))
            }
        }
    }

    func testMaterialConstraintsAndTransmissionOverrideDoNotChangeTheSavedPaper() throws {
        let negative = try result(request(.film))
        XCTAssertEqual(negative.renderMedium, "negative")
        XCTAssertFalse(negative.available.contains(.slideMount))
        let slide = try result(request(.slideMount, stock: "ektachromee100", medium: "ilfochrome-cps-1k"))
        XCTAssertEqual(slide.renderMedium, "screen")
        // The inverted scan keeps a positive medium and scans a negative one.
        XCTAssertNil(try result(request(.filmPositive)).renderMedium)
        XCTAssertEqual(try result(request(.filmPositive, medium: "negative")).renderMedium, "lab-scan")
        let positiveSlide = try result(request(.filmPositive, stock: "ektachromee100", medium: "ilfochrome-cps-1k"))
        XCTAssertEqual(positiveSlide.configuration.frame, .none)
        XCTAssertFalse(positiveSlide.available.contains(.filmPositive))
        XCTAssertEqual(try result(request(.filmPositive)).palette["cutout"], [0, 0, 0])
        let unavailable = try result(request(.slideMount))
        XCTAssertEqual(unavailable.configuration.frame, .none)
        XCTAssertNil(unavailable.renderMedium)
        let normal = try result(request(.film, stock: nil))
        XCTAssertEqual(normal.configuration.frame, .none)
        XCTAssertFalse(normal.available.contains(.film))
        XCTAssertTrue(normal.available.contains(.socialStory))
        // The browser does not develop the film beyond the gate that Emulsion Border prints.
        let emulsion = try result(request(.emulsion))
        XCTAssertEqual(emulsion.configuration.frame, .none)
        XCTAssertFalse(emulsion.available.contains(.emulsion))
        let projected = try result(request(.paper, medium: "vision-2383"))
        XCTAssertEqual(projected.configuration.frame, .none)
        for format in ["35mm", "super35", "16mm", "super8", "120", "4x5"] {
            let plan = try result(request(.film, format: format))
            XCTAssertEqual(plan.configuration.geometry, FilmBorderGeometry.preset(format))
        }
    }

    func testBorderWidthScalesPresentationMarginsAndLeavesPhysicalFramesAlone() throws {
        let preset = try result(request(.mount))
        XCTAssertEqual(preset.configuration.margin, 1)
        XCTAssertEqual(preset.placement.size.width, 300 + 2 * 16)
        let wide = try result(request(.mount, margin: 2))
        XCTAssertEqual(wide.configuration.margin, 2)
        XCTAssertEqual(wide.placement.size.width, 300 + 2 * 32)
        XCTAssertEqual(wide.placement.size.height, 200 + 2 * 32)
        XCTAssertEqual(wide.placement.image.x, 32)
        let flush = try result(request(.darkMount, margin: 0))
        XCTAssertEqual(flush.placement.size.width, 300)
        XCTAssertEqual(flush.placement.size.height, 200)

        // A cut sheet keeps its size, so a wider easel margin prints a smaller picture.
        let sheet = try result(request(.paper)), wideSheet = try result(request(.paper, margin: 3))
        XCTAssertEqual(wideSheet.configuration.sheet?.marginMM, 9)
        XCTAssertEqual(wideSheet.materialSize, sheet.materialSize)
        XCTAssertGreaterThan(wideSheet.placement.size.width, sheet.placement.size.width)
        let carrier = try result(request(.carrier, margin: 0.5))
        XCTAssertEqual(carrier.configuration.sheet?.marginMM, 6.35)
        XCTAssertEqual(carrier.configuration.sheet?.rebateMM, 2.5)

        let post = try result(request(.socialSquare)), widePost = try result(request(.socialSquare, margin: 2))
        XCTAssertEqual(widePost.configuration.canvas?.margin ?? 0, 0.1, accuracy: 1e-12)
        XCTAssertGreaterThan(widePost.placement.size.width, post.placement.size.width)
        XCTAssertEqual(widePost.placement.size.width, widePost.placement.size.height)

        for frame in [PrintFrame.film, .slideMount, .none] {
            let stock = frame == .slideMount ? "ektachromee100" : "gold200"
            let paper = frame == .slideMount ? "ilfochrome-cps-1k" : "ektacolor-edge"
            let plain = try result(request(frame, stock: stock, medium: paper))
            let scaled = try result(request(frame, stock: stock, medium: paper, margin: 3))
            XCTAssertNil(scaled.configuration.margin)
            XCTAssertEqual(scaled.configuration, plain.configuration)
            XCTAssertEqual(scaled.placement, plain.placement)
        }
        for margin in [-0.1, 3.1] {
            XCTAssertThrowsError(try result(request(.mount, margin: margin)))
        }
    }

    func testInvalidDimensionsAndUnknownMaterialAreRejectedWithoutLosingWorker() throws {
        for size in [(0, 200), (-1, 200), (32769, 1), (15000, 15000), (32768, 1)] {
            XCTAssertThrowsError(try result(request(.socialStory, width: size.0, height: size.1)))
        }
        XCTAssertThrowsError(try result(request(.film, format: "unknown")))
        XCTAssertThrowsError(try result(request(.paper, medium: "unknown")))
        XCTAssertEqual(try result(request(.mount)).configuration.frame, .mount)
    }
}
