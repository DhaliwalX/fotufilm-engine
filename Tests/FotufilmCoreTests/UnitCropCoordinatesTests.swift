import CoreGraphics
import XCTest
@testable import FotufilmImaging

final class UnitCropCoordinatesTests: XCTestCase {
    func testVerticalFlipConvertsBetweenDisplayAndCoreImageCoordinates() {
        let topOrigin = CGRect(x: 0.15, y: 0.10, width: 0.60, height: 0.25)
        let bottomOrigin = UnitCropCoordinates.verticallyFlipped(topOrigin)

        XCTAssertEqual(bottomOrigin.minX, 0.15, accuracy: 1e-12)
        XCTAssertEqual(bottomOrigin.minY, 0.65, accuracy: 1e-12)
        XCTAssertEqual(bottomOrigin.width, 0.60, accuracy: 1e-12)
        XCTAssertEqual(bottomOrigin.height, 0.25, accuracy: 1e-12)
    }

    func testVerticalFlipRoundTripsAnOffCenterCrop() {
        let original = CGRect(x: 0.21, y: 0.58, width: 0.44, height: 0.19)
        let roundTrip = UnitCropCoordinates.verticallyFlipped(
            UnitCropCoordinates.verticallyFlipped(original))

        XCTAssertEqual(roundTrip.minX, original.minX, accuracy: 1e-12)
        XCTAssertEqual(roundTrip.minY, original.minY, accuracy: 1e-12)
        XCTAssertEqual(roundTrip.width, original.width, accuracy: 1e-12)
        XCTAssertEqual(roundTrip.height, original.height, accuracy: 1e-12)
    }

    func testOptionalVerticalFlipPreservesNoCrop() {
        let crop: CGRect? = nil
        XCTAssertNil(UnitCropCoordinates.verticallyFlipped(crop))
    }
}
