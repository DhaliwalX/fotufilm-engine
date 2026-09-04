import XCTest
@testable import FotufilmCore

final class SensorFrameTests: XCTestCase {
    func testFocalPlaneInchesGivesTheFullFrame() throws {
        let frame = try XCTUnwrap(SensorFrame.focalPlane(
            xResolution: 4245.1, yResolution: 4233.3, unit: 2,
            pixelWidth: 6000, pixelHeight: 4000))
        XCTAssertEqual(frame.longSideMM, 35.9, accuracy: 0.05)
        XCTAssertEqual(frame.shortSideMM, 24.0, accuracy: 0.05)
        XCTAssertEqual(frame.cropFactor, 1, accuracy: 0.01)
        XCTAssertEqual(frame.derivation, .focalPlane)
    }

    func testFocalPlaneUnitsAgree() throws {
        let inches = try XCTUnwrap(SensorFrame.focalPlane(
            xResolution: 4245.1, yResolution: 4233.3, unit: 2,
            pixelWidth: 6000, pixelHeight: 4000))
        let centimetres = try XCTUnwrap(SensorFrame.focalPlane(
            xResolution: 4245.1 / 2.54, yResolution: 4233.3 / 2.54, unit: 3,
            pixelWidth: 6000, pixelHeight: 4000))
        let millimetres = try XCTUnwrap(SensorFrame.focalPlane(
            xResolution: 4245.1 / 25.4, yResolution: 4233.3 / 25.4, unit: 4,
            pixelWidth: 6000, pixelHeight: 4000))
        XCTAssertEqual(centimetres.shortSideMM, inches.shortSideMM, accuracy: 0.01)
        XCTAssertEqual(millimetres.shortSideMM, inches.shortSideMM, accuracy: 0.01)

        // Unit 1 means the resolution is a bare number, which cannot be turned into millimetres —
        // and reading it as any of the three above would put the frame out by 25.4 or more.
        XCTAssertNil(SensorFrame.focalPlane(xResolution: 4245.1, yResolution: 4233.3,
                                            unit: 1, pixelWidth: 6000, pixelHeight: 4000))
    }

    func testEquivalentFocalGivesAPSC() throws {
        let frame = try XCTUnwrap(SensorFrame.equivalentFocal(
            focalLengthMM: 23, equivalent35mmMM: 35,
            pixelWidth: 6000, pixelHeight: 4000))
        XCTAssertEqual(frame.longSideMM, 23.5, accuracy: 0.25)
        XCTAssertEqual(frame.shortSideMM, 15.6, accuracy: 0.25)
        XCTAssertEqual(frame.cropFactor, 1.522, accuracy: 0.01)
        XCTAssertEqual(frame.derivation, .equivalentFocalLength)
    }

    func testEquivalentFocalGivesAPhoneFrame() throws {
        let frame = try XCTUnwrap(SensorFrame.equivalentFocal(
            focalLengthMM: 6.765, equivalent35mmMM: 24,
            pixelWidth: 8064, pixelHeight: 6048))
        XCTAssertEqual(frame.longSideMM, 9.76, accuracy: 0.2)
        XCTAssertEqual(frame.shortSideMM, 7.32, accuracy: 0.15)
        XCTAssertLessThan(frame.shortSideMM, FilmFormat.sixteenMM.frameHeightMM)
        XCTAssertGreaterThan(frame.shortSideMM, FilmFormat.super8.frameHeightMM)
    }

    func testPortraitPixelsGiveTheSameFrame() throws {
        let landscape = try XCTUnwrap(SensorFrame.equivalentFocal(
            focalLengthMM: 35, equivalent35mmMM: 53,
            pixelWidth: 6000, pixelHeight: 4000))
        let portrait = try XCTUnwrap(SensorFrame.equivalentFocal(
            focalLengthMM: 35, equivalent35mmMM: 53,
            pixelWidth: 4000, pixelHeight: 6000))
        XCTAssertEqual(landscape, portrait)
    }

    func testImplausibleFramesAreRefused() {
        // Inches misread as millimetres: a 36 mm frame becomes 1.4 mm, under any sensor made.
        XCTAssertNil(SensorFrame.focalPlane(xResolution: 4245.1, yResolution: 4233.3,
                                            unit: 4, pixelWidth: 6000, pixelHeight: 4000))
        // Millimetres misread as inches: the same frame becomes 914 mm.
        XCTAssertNil(SensorFrame.focalPlane(xResolution: 4245.1 / 25.4,
                                            yResolution: 4233.3 / 25.4, unit: 2,
                                            pixelWidth: 6000, pixelHeight: 4000))
        // Nothing to divide by, and nothing to divide.
        XCTAssertNil(SensorFrame.focalPlane(xResolution: 0, yResolution: 4233.3, unit: 2,
                                            pixelWidth: 6000, pixelHeight: 4000))
        XCTAssertNil(SensorFrame.focalPlane(xResolution: 4245.1, yResolution: 4233.3, unit: 2,
                                            pixelWidth: 0, pixelHeight: 4000))
        XCTAssertNil(SensorFrame.equivalentFocal(focalLengthMM: 0, equivalent35mmMM: 24,
                                                 pixelWidth: 4000, pixelHeight: 3000))
        // A panorama's shape on a sensor's dimensions: the two numbers did not come from one frame.
        XCTAssertNil(SensorFrame(longSideMM: 60, shortSideMM: 12,
                                 derivation: .focalPlane))
    }

    func testAResizedExportIsReadFromTheEquivalentRatherThanTheStaleRecord() throws {
        let stale = try XCTUnwrap(SensorFrame.focalPlane(
            xResolution: 1966.837738, yResolution: 1966.837738, unit: 3,
            pixelWidth: 1462, pixelHeight: 1046))
        XCTAssertEqual(stale.shortSideMM, 5.32, accuracy: 0.05)
        XCTAssertEqual(stale.gauge.id, "16mm")
        // The lens was a 70 mm reported as a 70 mm equivalent, which is a full frame body and says
        // so however many pixels the file was saved at.
        let equivalent = try XCTUnwrap(SensorFrame.equivalentFocal(
            focalLengthMM: 70, equivalent35mmMM: 70,
            pixelWidth: 1462, pixelHeight: 1046))

        let read = try XCTUnwrap(SensorFrame.measured(focalPlane: stale,
                                                      equivalentFocal: equivalent))
        XCTAssertEqual(read.derivation, .equivalentFocalLength)
        // 25.2 rather than 24: the export was cropped as well as resized, and the equivalent route
        // lays the 135 diagonal over the shape the file delivers, so a 1.40:1 crop of a 3:2 frame
        // reads a millimetre tall. That is a rounding beside the 4.7x the stale record was out by,
        // and it lands on the same gauge the camera was.
        XCTAssertEqual(read.shortSideMM, 25.2, accuracy: 0.5)
        XCTAssertEqual(read.gauge.id, "35mm")
    }

    func testTheMeasuredFrameWinsWhileTheEquivalentAgrees() throws {
        let measured = try XCTUnwrap(SensorFrame.focalPlane(
            xResolution: 4245.1, yResolution: 4233.3, unit: 2,
            pixelWidth: 6000, pixelHeight: 4000))
        let inferred = try XCTUnwrap(SensorFrame.equivalentFocal(
            focalLengthMM: 70, equivalent35mmMM: 70,
            pixelWidth: 6000, pixelHeight: 4000))
        let read = try XCTUnwrap(SensorFrame.measured(focalPlane: measured,
                                                      equivalentFocal: inferred))
        XCTAssertEqual(read, measured)
        XCTAssertEqual(read.derivation, .focalPlane)

        // And either record alone is taken as it stands — the check is a corroboration, not a
        // requirement, and most files carry only one of the two.
        XCTAssertEqual(SensorFrame.measured(focalPlane: measured, equivalentFocal: nil), measured)
        XCTAssertEqual(SensorFrame.measured(focalPlane: nil, equivalentFocal: inferred), inferred)
        XCTAssertNil(SensorFrame.measured(focalPlane: nil, equivalentFocal: nil))
    }

    func testTheToleranceClearsRoundingAndStopsShortOfAGaugeStep() {
        let halfStep = (FilmFormat.sixteenMM.frameHeightMM
                        * FilmFormat.super35.frameHeightMM).squareRoot()
            / FilmFormat.sixteenMM.frameHeightMM
        XCTAssertGreaterThan(SensorFrame.corroborationTolerance, 0.08)
        XCTAssertLessThan(1 + SensorFrame.corroborationTolerance, halfStep)
    }

    func testMatchedGaugeIsThePresetEntire() throws {
        // APS-C: a 1.51x crop, which is a 23.8 x 15.9 mm frame.
        let frame = try XCTUnwrap(SensorFrame.equivalentFocal(
            focalLengthMM: 35, equivalent35mmMM: 53,
            pixelWidth: 6000, pixelHeight: 4000))
        let gauge = frame.gauge
        XCTAssertEqual(gauge.id, "super35")
        XCTAssertEqual(gauge.format, FilmFormat.super35)
        XCTAssertEqual(gauge.format, FilmFormat.preset(id: gauge.id))
        // The 18.7 mm gauge requires a recorded stretch from the 15.9 mm source frame.
        XCTAssertEqual(frame.gaugeStretch, 18.7 / frame.shortSideMM, accuracy: 0.01)
    }

    func testEveryMatchIsAPresetTheUserCanPick() {
        for id in FilmFormat.sensorMatchIDs {
            XCTAssertNotNil(FilmFormat.preset(id: id), "\(id) is matched but not offered")
            XCTAssertTrue(FilmFormat.presets.contains { $0.id == id },
                          "\(id) is missing from the picker's list")
        }
    }

    func testTheCamerasOfTheWorldLandOnTheGaugesTheyResemble() throws {
        let cameras: [(name: String, longMM: Float, shortMM: Float, gauge: String)] = [
            ("1/2.3-inch compact", 6.17, 4.55, "16mm"),
            ("iPhone 16 Pro at 2x", 4.88, 3.66, "16mm"),
            ("iPhone 17 main", 7.93, 5.95, "16mm"),
            ("1-inch", 13.2, 8.8, "16mm"),
            ("Four Thirds", 17.3, 13.0, "super35"),
            ("Canon APS-C", 22.3, 14.9, "super35"),
            ("Sony APS-C", 23.5, 15.6, "super35"),
            ("full frame", 36.0, 24.0, "35mm"),
            ("Fujifilm GFX", 43.8, 32.9, "35mm"),
        ]
        for camera in cameras {
            let frame = SensorFrame(longSideMM: camera.longMM, shortSideMM: camera.shortMM,
                                    derivation: .focalPlane)
            XCTAssertEqual(try XCTUnwrap(frame).gauge.id, camera.gauge,
                           "\(camera.name) landed on the wrong gauge")
        }
        // Full frame is 135 to the millimetre, so it should not be paying for the match at all.
        let fullFrame = SensorFrame(longSideMM: 36, shortSideMM: 24, derivation: .focalPlane)
        XCTAssertEqual(try XCTUnwrap(fullFrame).gaugeStretch, 1, accuracy: 0.0001)
    }

    func testTheMatchIsMadeOnEnlargementRatherThanMillimetres() {
        XCTAssertEqual(FilmFormat.nearest(toFrameHeightMM: 13.0).id, "super35")
        XCTAssertEqual(13.0 - FilmFormat.sixteenMM.frameHeightMM,
                       FilmFormat.super35.frameHeightMM - 13.0, accuracy: 0.15)
        // The turning point sits at the geometric mean of the two, not the arithmetic one.
        let geometric = (FilmFormat.sixteenMM.frameHeightMM
                         * FilmFormat.super35.frameHeightMM).squareRoot()
        XCTAssertEqual(FilmFormat.nearest(toFrameHeightMM: geometric - 0.1).id, "16mm")
        XCTAssertEqual(FilmFormat.nearest(toFrameHeightMM: geometric + 0.1).id, "super35")
    }

    func testInstaxIsOfferedButNeverMatched() {
        XCTAssertEqual(FilmFormat.instaxSquare.frameHeightMM,
                       FilmFormat.instaxWide.frameHeightMM)
        for id in ["instaxmini", "instaxsquare", "instaxwide"] {
            XCTAssertTrue(FilmFormat.presets.contains { $0.id == id })
            XCTAssertFalse(FilmFormat.sensorMatchIDs.contains(id))
        }
        // A frame the size of an instax mini sheet still lands on film, not on a print.
        XCTAssertEqual(FilmFormat.nearest(toFrameHeightMM: 46).id, "120")
    }

    func testTheSmallestGaugeIsOfferedButNeverMatched() {
        XCTAssertTrue(FilmFormat.presets.contains { $0.id == "super8" })
        XCTAssertFalse(FilmFormat.sensorMatchIDs.contains("super8"))

        // A 1× frame and a real 2× crop of the same phone sensor must infer the same minimum gauge.
        let wide = FilmFormat.nearest(toFrameHeightMM: 7.32)
        let cropped = FilmFormat.nearest(toFrameHeightMM: 3.66)
        XCTAssertEqual(wide.id, "16mm")
        XCTAssertEqual(cropped.id, wide.id)

        // Rounding up to the floor is a stretch, and it is counted rather than hidden: a 3.66 mm
        // frame on 16mm is asking 7.4 mm of film to stand in for half that.
        let frame = SensorFrame(longSideMM: 4.88, shortSideMM: 3.66, derivation: .focalPlane)
        XCTAssertEqual(frame?.gaugeStretch ?? 0, 7.4 / 3.66, accuracy: 0.01)
    }

    func testResolutionPrefersTheChoiceThenTheCameraThenTheFilm() throws {
        let frame = try XCTUnwrap(SensorFrame.equivalentFocal(
            focalLengthMM: 35, equivalent35mmMM: 53,
            pixelWidth: 6000, pixelHeight: 4000))
        // An unknown stock is developed on the house gauge, so this holds with no pack installed.
        let stockID = "no-such-stock"
        XCTAssertEqual(FilmFormat.native(forStockID: stockID), .still35)

        // Nothing said and nothing measured: the film's own gauge.
        XCTAssertEqual(
            FilmFormat.resolved(chosenID: nil, sensor: nil, stockID: stockID), .still35)

        // Nothing said, a frame measured: the gauge nearest the camera's, which is a smaller piece
        // of film than 135 and is why the grain moves at all. The whole gauge comes across,
        // including the cine base 16mm and Super 35 are coated on — the automatic answer is the
        // preset, not a size wearing its name.
        let automatic = FilmFormat.resolved(chosenID: nil, sensor: frame, stockID: stockID)
        XCTAssertEqual(automatic, .super35)
        XCTAssertLessThan(automatic.frameHeightMM, FilmFormat.still35.frameHeightMM)
        XCTAssertNotEqual(automatic.base, FilmFormat.still35.base)

        // Asked for by hand: the answer, whatever the file measured.
        XCTAssertEqual(
            FilmFormat.resolved(chosenID: "120", sensor: frame, stockID: stockID),
            .mediumFormat120)
        // A choice the pack no longer carries is still a choice — it falls back to the film rather
        // than reaching past it to the sensor.
        XCTAssertEqual(
            FilmFormat.resolved(chosenID: "70mm", sensor: frame, stockID: stockID), .still35)
    }

    func testSensorGaugeConfiguresTheEngineSmaller() throws {
        let frame = try XCTUnwrap(SensorFrame.equivalentFocal(
            focalLengthMM: 6.765, equivalent35mmMM: 24,
            pixelWidth: 8064, pixelHeight: 6048))
        var onFilm = FotufilmEngine.Options()
        onFilm.format = .still35
        var onSensor = onFilm
        onSensor.format = FilmFormat.resolved(chosenID: nil, sensor: frame,
                                              stockID: "no-such-stock")
        let stock = TestStocks.negative
        let filmInvocation = FilmEngineInvocation(stock: stock, options: onFilm,
                                                  width: 512, height: 384)
        let sensorInvocation = FilmEngineInvocation(stock: stock, options: onSensor,
                                                    width: 512, height: 384)
        XCTAssertNotEqual(filmInvocation.configuration, sensorInvocation.configuration)

        // And it is the configuration picking that gauge by hand would have produced, to the last
        // word: a 7.3 mm frame is nearest 16mm, and the two routes to 16mm have to agree or one of
        // them is describing a film that does not exist.
        var byHand = onFilm
        byHand.format = .sixteenMM
        XCTAssertEqual(
            FilmEngineInvocation(stock: stock, options: byHand,
                                 width: 512, height: 384).configuration,
            sensorInvocation.configuration)
    }
}
