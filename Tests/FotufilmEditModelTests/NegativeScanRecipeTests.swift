import CoreGraphics
import XCTest
@testable import FotufilmCore
@testable import FotufilmEditModel

final class NegativeScanRecipeTests: XCTestCase {
    private var negative: FilmStock {
        get throws { try XCTUnwrap(FilmStock.presets["example-negative-400"]) }
    }

    func testOrientationRoundTripsEveryTurnAndMirror() {
        let point = CGPoint(x: 0.2, y: 0.7)
        for turns in 0..<4 {
            for mirrored in [false, true] {
                var recipe = NegativeScanRecipe()
                recipe.quarterTurns = turns
                recipe.mirrored = mirrored
                let back = recipe.unorient(recipe.orient(point))
                XCTAssertEqual(back.x, point.x, accuracy: 1e-12)
                XCTAssertEqual(back.y, point.y, accuracy: 1e-12)
            }
        }
    }

    func testClockwiseTurnMovesTheTopLeftToTheTopRight() {
        var recipe = NegativeScanRecipe()
        recipe.rotateClockwise()
        let corner = recipe.orient(CGPoint(x: 0, y: 0))
        XCTAssertEqual(corner, CGPoint(x: 1, y: 0))
        XCTAssertEqual(recipe.orientedSize(of: CGSize(width: 300, height: 200)),
                       CGSize(width: 200, height: 300))
    }

    /// Mirror flips what is shown left to right at every rotation, and the crop keeps framing the
    /// same part of the scan through turns and flips.
    func testMirrorFlipsTheShownPictureAndTheCropFollowsTheScan() {
        let scanPoint = CGPoint(x: 0.1, y: 0.3)
        for turns in 0..<4 {
            var recipe = NegativeScanRecipe()
            recipe.quarterTurns = turns
            recipe.crop = .init(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
            let framed = recipe.unorient(recipe.crop)
            let shown = recipe.orient(scanPoint)
            recipe.toggleMirror()
            let flipped = recipe.orient(scanPoint)
            XCTAssertEqual(flipped.x, 1 - shown.x, accuracy: 1e-12, "turns \(turns)")
            XCTAssertEqual(flipped.y, shown.y, accuracy: 1e-12, "turns \(turns)")
            recipe.rotateClockwise()
            let kept = recipe.unorient(recipe.crop)
            XCTAssertEqual(kept.x, framed.x, accuracy: 1e-12)
            XCTAssertEqual(kept.y, framed.y, accuracy: 1e-12)
            XCTAssertEqual(kept.width, framed.width, accuracy: 1e-12)
            XCTAssertEqual(kept.height, framed.height, accuracy: 1e-12)
        }
    }

    func testRecipeRoundTripsThroughJSON() throws {
        var recipe = NegativeScanRecipe()
        recipe.conversion = .film
        recipe.border = [0.8, 0.5, 0.3]
        recipe.borderArea = .init(x: 0.01, y: 0.02, width: 0.03, height: 0.04)
        recipe.paperID = PrintPaper.crystalArchive.rawValue
        recipe.exposure = 0.5
        recipe.warmth = -0.25
        recipe.quarterTurns = 3
        recipe.mirrored = true
        let data = try JSONEncoder().encode(recipe)
        XCTAssertEqual(try JSONDecoder().decode(NegativeScanRecipe.self, from: data), recipe)
    }

    /// On an enlarged paper, exposure and colour are the enlarger's: printer exposure and M/Y
    /// filtration, with nothing left for a display gain.
    func testPaperPrintsCarryExposureAndColourOnTheEnlarger() throws {
        let stock = try negative
        var recipe = NegativeScanRecipe()
        recipe.conversion = .film
        recipe.paperID = PrintPaper.crystalArchive.rawValue
        recipe.exposure = 1
        recipe.warmth = 1
        recipe.tint = -1
        let options = recipe.printOptions(for: stock)
        XCTAssertEqual(options.stage, .print)
        XCTAssertEqual(options.paper, .crystalArchive)
        let printer = try XCTUnwrap(options.printer)
        let reference = PrinterProfile.simulatedTungsten
        XCTAssertEqual(printer.exposureEV, 1)
        XCTAssertLessThan(printer.yellow, reference.yellow, "warming removes yellow filtration")
        XCTAssertGreaterThan(printer.magenta, reference.magenta, "going green adds magenta")
        XCTAssertEqual(options.screenExposureEV, 0)
        XCTAssertEqual(recipe.displayGains(printingOn: stock), SIMD3(repeating: 1))
    }

    /// A lab printer times each negative: a frame whose highlights sit at diffuse white prints at
    /// the reference timing, and a thinner one takes less light.
    func testPaperIsTimedByTheFramesHighlights() throws {
        let stock = try negative
        var recipe = NegativeScanRecipe()
        recipe.paperID = PrintPaper.crystalArchive.rawValue
        let white = NegativeScanRecipe.diffuseWhiteStops
        let normal = try XCTUnwrap(recipe.printOptions(for: stock, highlightStops: white).printer)
        XCTAssertEqual(normal.exposureEV, 0, accuracy: 1e-5)
        let thin = try XCTUnwrap(recipe.printOptions(for: stock, highlightStops: white - 1).printer)
        XCTAssertLessThan(thin.exposureEV, 0)
        recipe.exposure = 0.5
        let lifted = try XCTUnwrap(recipe.printOptions(for: stock, highlightStops: white - 1).printer)
        XCTAssertEqual(lifted.exposureEV, thin.exposureEV + 0.5, accuracy: 1e-5)
        XCTAssertEqual(recipe.printOptions(for: stock, highlightStops: 1).sceneHighlightStops, 1)
    }

    func testDigitalReferenceTakesScreenExposureAndADisplayBalance() throws {
        let stock = try negative
        var recipe = NegativeScanRecipe()
        recipe.conversion = .film
        recipe.exposure = -1
        recipe.warmth = 1
        let options = recipe.printOptions(for: stock)
        XCTAssertEqual(options.paper, .screen)
        XCTAssertNil(options.printer)
        XCTAssertEqual(options.screenExposureEV, -1)
        let gains = recipe.displayGains(printingOn: stock)
        XCTAssertGreaterThan(gains.x, gains.z, "warmer carries more red than blue")
        XCTAssertEqual(gains.y, 1, accuracy: 1e-6, "exposure rides the screen, not the gain")
    }

    func testAutomaticGainsCarryExposureAndDropColourForMonochrome() {
        var recipe = NegativeScanRecipe()
        recipe.exposure = 1
        recipe.tint = 1
        let colour = recipe.displayGains(printingOn: nil)
        XCTAssertLessThan(colour.y, 2, "magenta lowers green")
        recipe.monochrome = true
        XCTAssertEqual(recipe.displayGains(printingOn: nil), SIMD3(repeating: 2))
    }

    func testUnavailableReceiverFallsBackToTheFirstOffered() throws {
        let stock = try negative
        var recipe = NegativeScanRecipe()
        recipe.paperID = PrintPaper.vision2383.rawValue
        XCTAssertFalse(NegativeScanRecipe.papers(for: stock).contains(.vision2383))
        XCTAssertEqual(recipe.paper(for: stock), .screen)
    }

    func testCropStaysInsideTheFrame() {
        let area = NegativeScanRecipe.Area(x: 0.9, y: -0.2, width: 0.5, height: 0.01).clamped()
        XCTAssertEqual(area.x + area.width, 1, accuracy: 1e-12)
        XCTAssertEqual(area.y, 0)
        XCTAssertEqual(area.height, 0.05, accuracy: 1e-12)
    }
    func testToneIsNeutralAtRestAndKeepsEveryHue() {
        let rgb = SIMD3<Float>(0.3, 0.12, 0.05)
        XCTAssertEqual(NegativeScanTone().apply(rgb), rgb)
        let toned = NegativeScanTone(contrast: 0.7, highlights: -0.4, shadows: 0.5).apply(rgb)
        XCTAssertEqual(toned.x / toned.y, rgb.x / rgb.y, accuracy: 1e-5)
        XCTAssertEqual(toned.z / toned.y, rgb.z / rgb.y, accuracy: 1e-5)
    }

    /// Every setting at either end still gives a rising curve, and contrast leaves mid-grey be.
    func testToneCurveAlwaysRisesAndPivotsOnMidGrey() {
        for contrast: Float in [-1, 0, 1] { for highlights: Float in [-1, 1] {
            for shadows: Float in [-1, 1] {
                let tone = NegativeScanTone(contrast: contrast, highlights: highlights,
                                            shadows: shadows)
                var last = -Float.infinity
                for step in -80...80 {
                    let out = tone.curve(Float(step) / 10)
                    XCTAssertGreaterThan(out, last, "\(contrast) \(highlights) \(shadows)")
                    last = out
                }
                XCTAssertEqual(tone.curve(0), 0)
            }
        } }
        let steeper = NegativeScanTone(contrast: 1)
        XCTAssertGreaterThan(steeper.curve(2), 2)
        XCTAssertLessThan(steeper.curve(-2), -2)
    }

    func testPaperGradeTwoIsNormalContrastAndGradesRoundTrip() {
        XCTAssertEqual(NegativeScanRecipe.contrast(forGrade: 2), 0)
        XCTAssertGreaterThan(NegativeScanRecipe.contrast(forGrade: 5), 0)
        XCTAssertLessThan(NegativeScanRecipe.contrast(forGrade: 0), 0)
        for grade in stride(from: 0.0, through: 5, by: 0.5) {
            XCTAssertEqual(NegativeScanRecipe.grade(
                forContrast: NegativeScanRecipe.contrast(forGrade: grade)), grade, accuracy: 1e-5)
        }
    }

    /// A pasted conversion brings everything but the frame's own framing.
    func testAdoptedConversionKeepsTheFrameOwnFraming() {
        var source = NegativeScanRecipe()
        source.conversion = .film
        source.stockID = "portra400"
        source.border = [0.7, 0.4, 0.2]
        source.exposure = 0.4
        source.contrast = 0.3
        source.lightFrameID = "light"
        source.quarterTurns = 1
        source.crop = .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        var frame = NegativeScanRecipe()
        frame.quarterTurns = 3
        frame.mirrored = true
        frame.straighten = 2
        frame.crop = .init(x: 0.2, y: 0, width: 0.6, height: 1)
        let framing = (frame.quarterTurns, frame.mirrored, frame.straighten, frame.crop)
        frame.adoptConversion(of: source)
        XCTAssertEqual(frame.stockID, "portra400")
        XCTAssertEqual(frame.border, source.border)
        XCTAssertEqual(frame.contrast, 0.3)
        XCTAssertEqual(frame.lightFrameID, "light")
        XCTAssertEqual(frame.quarterTurns, framing.0)
        XCTAssertEqual(frame.mirrored, framing.1)
        XCTAssertEqual(frame.straighten, framing.2)
        XCTAssertEqual(frame.crop, framing.3)
    }

    func testFlippingLeansTheTiltTheOtherWay() {
        var recipe = NegativeScanRecipe()
        recipe.straighten = 4
        recipe.toggleMirror()
        XCTAssertEqual(recipe.straighten, -4)
    }

    /// The straightened picture maps back inside the oriented one at every corner, its centre
    /// stays put, and the enlargement is exactly what keeps the corners inside.
    func testStraightenedPictureStaysInsideTheFrame() {
        let size = CGSize(width: 3000, height: 2000)
        var recipe = NegativeScanRecipe()
        XCTAssertEqual(recipe.unstraighten(CGPoint(x: 0.2, y: 0.9), orientedSize: size),
                       CGPoint(x: 0.2, y: 0.9))
        for degrees in [-15.0, -3, 7, 15] {
            recipe.straighten = degrees
            XCTAssertGreaterThan(NegativeScanRecipe.straightenScale(size: size, degrees: degrees), 1)
            let centre = recipe.unstraighten(CGPoint(x: 0.5, y: 0.5), orientedSize: size)
            XCTAssertEqual(centre.x, 0.5, accuracy: 1e-12)
            XCTAssertEqual(centre.y, 0.5, accuracy: 1e-12)
            var touching = 0
            for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1),
                           CGPoint(x: 1, y: 1)] {
                let p = recipe.unstraighten(corner, orientedSize: size)
                XCTAssertTrue((-1e-9...1 + 1e-9).contains(p.x) && (-1e-9...1 + 1e-9).contains(p.y),
                              "\(degrees)° corner \(corner) → \(p)")
                if min(p.x, p.y, 1 - p.x, 1 - p.y) < 1e-9 { touching += 1 }
            }
            XCTAssertGreaterThan(touching, 0, "the enlargement is no larger than it must be")
        }
    }
    func testARecipeSavedBeforeAControlExistedOpensWithItAtRest() throws {
        let saved = #"{"conversion":"film","stockID":"gold200","exposure":0.5}"#
        let recipe = try JSONDecoder().decode(NegativeScanRecipe.self, from: Data(saved.utf8))
        XCTAssertEqual(recipe.conversion, .film)
        XCTAssertEqual(recipe.exposure, 0.5)
        XCTAssertEqual(recipe.contrast, 0)
        XCTAssertEqual(recipe.straighten, 0)
        XCTAssertEqual(recipe.crop, .full)
        XCTAssertNil(recipe.lightFrameID)
    }
}
