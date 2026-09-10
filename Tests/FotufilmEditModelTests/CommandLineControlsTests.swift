import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class CommandLineControlsTests: XCTestCase {
    private func applying(_ field: EditorControlField, _ text: String) throws -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        try XCTUnwrap(EditorControlCatalogue.control(field)).applyCommandLineValue(text, to: &options)
        return options
    }

    func testFringeFlagsKeepTheirExistingLimits() throws {
        for value in ["-0.1", "1.1", "nan", "inf", "1e300"] {
            XCTAssertThrowsError(try applying(.chromaticFringeAmount, value), value)
        }
        for value in ["-1", "2001", "nan", "inf"] {
            XCTAssertThrowsError(try applying(.chromaticFringeRadius, value), value)
        }
        XCTAssertEqual(try applying(.chromaticFringeAmount, "0").chromaticFringeAmount, 0)
        XCTAssertEqual(try applying(.chromaticFringeAmount, "1").chromaticFringeAmount, 1)
        // The CLI's published range extends beyond the plugin slider's 300 µm.
        XCTAssertEqual(try applying(.chromaticFringeRadius, "2000").chromaticFringeRadiusMM, 2)
    }

    func testFlagUnitsAndChoicesReachTheIntendedOptions() throws {
        XCTAssertEqual(try applying(.exposure, "-1.5").exposureEV, -1.5)
        XCTAssertEqual(try applying(.halation, "0.5").halationScale, 0.5)
        XCTAssertEqual(try applying(.couplerReach, "2").couplerGapReachScales, [2, 2])
        XCTAssertEqual(try applying(.couplerSelf, "0").couplerSelfScale, 0)
        XCTAssertEqual(try applying(.halationModel, "layered").halationModel, .layered)
        XCTAssertEqual(try applying(.enlarger, "condenser").enlarger, .condenser)
        XCTAssertTrue(try applying(.estimatedHalation, "").useEstimatedHalationProfile)
        XCTAssertFalse(try applying(.localTone, "0").localTone)
        XCTAssertThrowsError(try applying(.halationModel, "unknown"))
    }
}
