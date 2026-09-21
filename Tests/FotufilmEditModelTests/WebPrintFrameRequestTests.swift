import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebPrintFrameRequestTests: XCTestCase {
    private func request(_ frame: PrintFrame, stock: String? = "gold200", format: String = "35mm",
                         medium: String = "ektacolor-edge", width: Int = 300, height: Int = 200) throws -> Data {
        var value: [String: Any] = ["kind": "print-frame", "frame": frame.rawValue,
            "format": format, "medium": medium, "width": width, "height": height]
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
        for frame in PrintFrame.allCases {
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
        let unavailable = try result(request(.slideMount))
        XCTAssertEqual(unavailable.configuration.frame, .none)
        XCTAssertNil(unavailable.renderMedium)
        let normal = try result(request(.film, stock: nil))
        XCTAssertEqual(normal.configuration.frame, .none)
        XCTAssertFalse(normal.available.contains(.film))
        XCTAssertTrue(normal.available.contains(.socialStory))
        let projected = try result(request(.paper, medium: "vision-2383"))
        XCTAssertEqual(projected.configuration.frame, .none)
        for format in ["35mm", "super35", "16mm", "super8", "120", "4x5"] {
            let plan = try result(request(.film, format: format))
            XCTAssertEqual(plan.configuration.geometry, FilmBorderGeometry.preset(format))
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
