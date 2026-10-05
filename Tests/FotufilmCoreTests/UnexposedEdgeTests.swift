import XCTest
@testable import FotufilmCore

final class UnexposedEdgeTests: XCTestCase {
    func testBandRunsToThePerforationsOrTheFilmEdge() throws {
        // 135: 5.5 mm from the film edge to the gate, of which 2.01 mm edge and a 2.794 mm
        // perforation; along the roll, half the 2 mm between frames.
        let still = try XCTUnwrap(UnexposedEdge.Geometry.preset("35mm"))
        XCTAssertEqual(still.top, 0.696, accuracy: 1e-9)
        XCTAssertEqual(still.bottom, 0.696, accuracy: 1e-9)
        XCTAssertEqual(still.left, 1, accuracy: 1e-9)
        XCTAssertEqual(still.right, 1, accuracy: 1e-9)
        // Unperforated gauges run to the cut edge.
        let medium = try XCTUnwrap(UnexposedEdge.Geometry.preset("120"))
        XCTAssertEqual(medium.left, 2.5, accuracy: 1e-9)
        XCTAssertEqual(medium.right, 2.5, accuracy: 1e-9)
        XCTAssertEqual(medium.bottom, 2, accuracy: 1e-9)
        let sheet = try XCTUnwrap(UnexposedEdge.Geometry.preset("4x5"))
        XCTAssertEqual([sheet.left, sheet.right, sheet.top, sheet.bottom], [2.5, 2.5, 2.5, 2.5])
        // Motion-picture gauges stop at their perforations on one or both sides.
        let super35 = try XCTUnwrap(UnexposedEdge.Geometry.preset("super35"))
        XCTAssertEqual(super35.left, 5.04 - 2.01 - 2.794, accuracy: 1e-9)
        XCTAssertEqual(super35.right, super35.left, accuracy: 1e-9)
        let sixteen = try XCTUnwrap(UnexposedEdge.Geometry.preset("16mm"))
        XCTAssertEqual(sixteen.left, 2.85 - 0.914 - 1.829, accuracy: 1e-9)
        XCTAssertEqual(sixteen.right, 16 - 2.85 - 12.35, accuracy: 1e-9)
        // Integral instant film has a mask beyond the image, not emulsion.
        for instant in ["instaxmini", "instaxsquare", "instaxwide"] {
            XCTAssertNil(UnexposedEdge.Geometry.preset(instant))
        }
        XCTAssertNil(UnexposedEdge.Geometry.preset("unknown"))
    }

    func testMarginsTurnWithTheCamera() throws {
        let still = try XCTUnwrap(UnexposedEdge.Geometry.preset("35mm"))
        let landscape = still.margins(photoWidth: 3600, photoHeight: 2400, pixelsPerMM: 100, carrier: false)
        XCTAssertEqual(landscape, .init(left: 100, right: 100, top: 70, bottom: 70))
        let portrait = still.margins(photoWidth: 2400, photoHeight: 3600, pixelsPerMM: 100, carrier: false)
        XCTAssertEqual(portrait, .init(left: 70, right: 70, top: 100, bottom: 100))
        let square = still.margins(photoWidth: 2400, photoHeight: 2400, pixelsPerMM: 100, carrier: false)
        XCTAssertEqual(square, landscape, "a square crop keeps the film's orientation")
        // A negative is printed in a carrier filed out to the band, and the film reaches past it.
        let printed = still.margins(photoWidth: 3600, photoHeight: 2400, pixelsPerMM: 100, carrier: true)
        let reach = Int((UnexposedEdge.carrierReachMM * 100).rounded(.up))
        XCTAssertEqual(printed, .init(left: 100 + reach, right: 100 + reach, top: 70 + reach,
                                      bottom: 70 + reach, carrier: reach))
    }

    func testGatePenumbraIsTheShareOfTheLensPupilPastTheEdge() {
        let radius = UnexposedEdge.gateRadiusMM()
        // The renderers' acos is good to 7e-5 radians, a few 1e-5 of the share.
        XCTAssertEqual(UnexposedEdge.gateTransmission(beyondMM: 0), 0.5, accuracy: 1e-4)
        XCTAssertEqual(UnexposedEdge.gateTransmission(beyondMM: -radius), 1)
        XCTAssertEqual(UnexposedEdge.gateTransmission(beyondMM: radius), 0)
        var previous: Float = 1
        for step in -20...20 {
            let x = radius * Float(step) / 20
            let t = UnexposedEdge.gateTransmission(beyondMM: x)
            XCTAssertLessThanOrEqual(t, previous)
            XCTAssertEqual(t + UnexposedEdge.gateTransmission(beyondMM: -x), 1, accuracy: 1e-4,
                           "the shadow of a straight edge is point-symmetric")
            previous = t
        }
    }

    func testTheGatesShadowFollowsTheTakingAperture() {
        // At the reference f/2 the shadow is the pupil's cone, the fringe adding under 1%.
        let cone = UnexposedEdge.gateSeparationMM / (2 * UnexposedEdge.referenceFNumber)
        XCTAssertEqual(UnexposedEdge.gateRadiusMM(), cone, accuracy: cone * 0.01)
        XCTAssertEqual(UnexposedEdge.gateRadiusMM(fNumber: 2), UnexposedEdge.gateRadiusMM())
        // Wide open the shadow is softer, stopped down sharper.
        let stops: [Float] = [1.4, 2, 2.8, 4, 5.6, 8, 11, 16, 22]
        let radii = stops.map { UnexposedEdge.gateRadiusMM(fNumber: $0) }
        for (wider, narrower) in zip(radii, radii.dropFirst()) { XCTAssertGreaterThan(wider, narrower) }
        // But never sharper than the edge's Fresnel fringe.
        let fringe = (UnexposedEdge.gateWavelengthMM * UnexposedEdge.gateSeparationMM).squareRoot() / 2
        XCTAssertEqual(UnexposedEdge.gateRadiusMM(fNumber: 128), fringe, accuracy: fringe * 0.01)
        XCTAssertGreaterThan(UnexposedEdge.gateTransmission(beyondMM: cone / 2, fNumber: 1.4),
                             UnexposedEdge.gateTransmission(beyondMM: cone / 2, fNumber: 2),
                             "a faster lens throws more light past the gate's edge")
    }

    func testTheTakingApertureIsTheSamePictureOnTheGauge() throws {
        // A full-frame camera's aperture is the 135 gate's.
        let fullFrame = SensorFrame(longSideMM: 36, shortSideMM: 24, derivation: .focalPlane)
        let leica = try XCTUnwrap(UnexposedEdge.TakingAperture(fNumber: 2.8, sensor: fullFrame))
        XCTAssertEqual(leica.equivalent(on: .still35), 2.8, accuracy: 1e-4)
        XCTAssertEqual(leica.equivalent(on: .mediumFormat120), 2.8 * 79.2 / 43.27, accuracy: 0.01,
                       "the same picture on 6x6 takes a larger f-number")
        // A phone's main camera, 6.765 mm at 24 mm equivalent: f/1.78 there is about f/6.3 on 135.
        let phone = try XCTUnwrap(SensorFrame.equivalentFocal(focalLengthMM: 6.765, equivalent35mmMM: 24,
                                                              pixelWidth: 4032, pixelHeight: 3024))
        let iPhone = try XCTUnwrap(UnexposedEdge.TakingAperture(fNumber: 1.78, sensor: phone))
        XCTAssertEqual(iPhone.equivalent(on: .still35), 1.78 * 24 / 6.765, accuracy: 0.01)
        // Without a measured sensor the picture is taken to have been exposed on the gauge.
        XCTAssertEqual(UnexposedEdge.TakingAperture(fNumber: 4, sensor: nil)?.equivalent(on: .still35), 4)
        // A file that says nothing believable leaves the reference aperture.
        for unreadable: Float? in [nil, 0, -2, .nan, .infinity, 400] {
            XCTAssertNil(UnexposedEdge.TakingAperture(fNumber: unreadable, sensor: fullFrame))
        }
    }

    func testTheLensImageContinuesPastThePhotographsEdges() {
        let width = 4, height = 3
        let margins = UnexposedEdge.Margins(left: 2, right: 1, top: 1, bottom: 2)
        var photo = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                photo[i] = Float(x); photo[i + 1] = Float(y); photo[i + 2] = 0.5; photo[i + 3] = 1
            }
        }
        let outer = (width: 7, height: 6)
        var extended = [Float](repeating: -1, count: outer.width * outer.height * 4)
        photo.withUnsafeBufferPointer { source in
            extended.withUnsafeMutableBufferPointer {
                UnexposedEdge.extend(source, width: width, height: height, margins: margins, into: $0)
            }
        }
        func pixel(_ x: Int, _ y: Int) -> [Float] {
            let i = (y * outer.width + x) * 4
            return Array(extended[i..<(i + 4)])
        }
        XCTAssertEqual(pixel(2, 1), [0, 0, 0.5, 1], "the photograph stands inside the margins")
        XCTAssertEqual(pixel(5, 3), [3, 2, 0.5, 1])
        XCTAssertEqual(pixel(0, 0), [0, 0, 0.5, 1], "corners continue the corner")
        XCTAssertEqual(pixel(6, 5), [3, 2, 0.5, 1])
        XCTAssertEqual(pixel(4, 0), [2, 0, 0.5, 1], "edges continue the edge")
        XCTAssertEqual(pixel(0, 2), [0, 1, 0.5, 1])
    }

    func testTheLargerFrameTakesItsScaleAndGateFromTheAperture() {
        var options = FotufilmEngine.Options()
        XCTAssertEqual(options.pixelsPerMM(width: 360, height: 240), 10)
        XCTAssertEqual(options.gateConfiguration(width: 360, height: 240), [0, 0, 0, 0, -1],
                       "a photograph's own develop has no gate")
        options.unexposedEdge = .init(margins: .init(left: 10, right: 10, top: 7, bottom: 7))
        XCTAssertEqual(options.frameShortEdgePixels(width: 380, height: 254), 240)
        XCTAssertEqual(options.pixelsPerMM(width: 380, height: 254), 10)
        let gate = options.gateConfiguration(width: 380, height: 254)
        XCTAssertEqual(Array(gate[0..<4]), [10, 7, 370, 247])
        XCTAssertEqual(gate[4], UnexposedEdge.gateRadiusMM() * 10, accuracy: 1e-6)
        XCTAssertEqual(options.gateCornerConfiguration(width: 380, height: 254),
                       UnexposedEdge.gateCornerRadiusMM * 10, accuracy: 1e-6)
        XCTAssertEqual(options.carrierConfiguration(width: 380, height: 254)[5], -1, "no carrier")
        options.unexposedEdge = .init(margins: .init(left: 14, right: 14, top: 11, bottom: 11, carrier: 4))
        let carrier = options.carrierConfiguration(width: 388, height: 262)
        XCTAssertEqual(Array(carrier[0..<4]), [4, 4, 384, 258], "the opening is filed out to the band")
        XCTAssertEqual(carrier[5], UnexposedEdge.carrierShadowRadiusMM * 10, accuracy: 1e-5)
        options.unexposedEdge = .init(margins: .init(left: 10, right: 10, top: 7, bottom: 7), fNumber: 8)
        XCTAssertEqual(options.gateConfiguration(width: 380, height: 254)[4],
                       UnexposedEdge.gateRadiusMM(fNumber: 8) * 10, accuracy: 1e-6,
                       "the shadow is the picture's own aperture's")
        options.unexposedEdge = nil
        XCTAssertEqual(options.gateCornerConfiguration(width: 360, height: 240), 0)
    }

    func testTheGatesCornersAreRounded() {
        let aperture = (left: Float(10), top: Float(10), right: Float(110), bottom: Float(60))
        func distance(_ x: Float, _ y: Float, corner: Float = 4) -> Float {
            UnexposedEdge.gateDistance(x: x, y: y, aperture: aperture, corner: corner)
        }
        // Along a side the distance is that side's alone, inside and out.
        XCTAssertEqual(distance(60, 7), 3, accuracy: 1e-5)
        XCTAssertEqual(distance(60, 12), -2, accuracy: 1e-5)
        XCTAssertEqual(distance(113, 35), 3, accuracy: 1e-5)
        // The rectangle's own corner lies beyond the rounded one by the radius's diagonal excess.
        let root2 = Float(2).squareRoot()
        XCTAssertEqual(distance(10, 10), 4 * (root2 - 1), accuracy: 1e-5)
        XCTAssertEqual(distance(10, 10, corner: 0), 0, accuracy: 1e-5)
        XCTAssertEqual(distance(14 - 4 / root2, 14 - 4 / root2), 0, accuracy: 1e-5,
                       "the arc passes the radius from its centre")
    }

    /// Develops a uniform photograph of `scene` light on a larger piece of film and returns the
    /// red record of the middle column: the band above the photograph, then its top rows.
    private func develop(scene: Float, carrier: Bool = false, fNumber: Float? = nil,
                         _ configure: (inout FotufilmEngine.Options) -> Void = { _ in })
        throws -> (column: [Float], margins: UnexposedEdge.Margins) {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.localTone = false
        configure(&options)
        let width = 720, height = 480
        let margins = try XCTUnwrap(UnexposedEdge.Geometry.preset("120"))
            .margins(photoWidth: width, photoHeight: height,
                     pixelsPerMM: options.pixelsPerMM(width: width, height: height), carrier: carrier)
        options.unexposedEdge = .init(margins: margins, fNumber: fNumber)
        let outerWidth = width + margins.left + margins.right
        let outerHeight = height + margins.top + margins.bottom
        let input = ImageBuffer(width: outerWidth, height: outerHeight, fill: scene)
        let output = try FotufilmEngine(stock: TestStocks.negative, options: options)
            .processChecked(linearRGB: input)
        let x = outerWidth / 2
        return ((0..<(margins.top + 20)).map { output.planes[0][$0 * outerWidth + x] }, margins)
    }

    func testTheGateShadesTheFilmAndTheFramesLightGlowsIntoIt() throws {
        let dark = try develop(scene: 0)
        let bright = try develop(scene: 4)
        let top = dark.margins.top
        XCTAssertEqual(top, 40, "120 runs 2 mm to the film edge")
        // Far from the gate both are the same unexposed film, whatever the lens formed.
        for c in [0, 1] { XCTAssertEqual(bright.column[c], dark.column[c], accuracy: 0.01) }
        // Beside a bright frame the film beyond the gate carries its glow, fading outward.
        XCTAssertGreaterThan(bright.column[top - 1] - dark.column[top - 1], 0.01,
                             "halation returns light past the gate")
        XCTAssertGreaterThan(bright.column[top - 1] - dark.column[top - 1],
                             bright.column[top / 2] - dark.column[top / 2])
        XCTAssertNotEqual(bright.column[top + 10], bright.column[top - 10],
                          "the photograph is exposed, the film beyond it is not")
    }

    func testAWideOpenLensSoftensTheGatesEdge() throws {
        let open = try develop(scene: 4, fNumber: 1)
        let stopped = try develop(scene: 4, fNumber: 22)
        let top = open.margins.top
        // Only the edge changes: the film far beyond the gate, and the picture well inside it,
        // develop the same.
        XCTAssertEqual(open.column[2], stopped.column[2], accuracy: 1e-4)
        XCTAssertEqual(open.column[top + 15], stopped.column[top + 15], accuracy: 1e-4)
        let edge = (top - 2...top + 1).map { abs(open.column[$0] - stopped.column[$0]) }.max() ?? 0
        XCTAssertGreaterThan(edge, 1e-3, "the wide-open shadow crosses the edge more softly")
    }

    func testLayeredTransportScattersPastTheGateOnce() throws {
        let layered: (inout FotufilmEngine.Options) -> Void = { $0.halationModel = .layered }
        let dark = try develop(scene: 0, layered)
        let bright = try develop(scene: 4, layered)
        let top = dark.margins.top
        for c in [0, 1] { XCTAssertEqual(bright.column[c], dark.column[c], accuracy: 0.01) }
        XCTAssertGreaterThan(bright.column[top - 1] - dark.column[top - 1], 0.01,
                             "the transported light returns past the gate")
        XCTAssertGreaterThan(bright.column[top - 1] - dark.column[top - 1],
                             bright.column[top / 2] - dark.column[top / 2])
    }

    func testTheCarrierHoldsThePrintingLightOffBeyondItsOpening() throws {
        let open = try develop(scene: 0)
        let printed = try develop(scene: 0, carrier: true)
        let reach = printed.margins.carrier
        XCTAssertGreaterThan(reach, 0)
        XCTAssertEqual(printed.margins.top, open.margins.top + reach)
        // The unexposed band prints as before inside the opening, and the paper beyond the carrier
        // saw no light: it is far lighter than the band.
        let band = printed.column[reach + open.margins.top / 2]
        XCTAssertEqual(band, open.column[open.margins.top / 2], accuracy: 1e-4)
        XCTAssertGreaterThan(printed.column[0], band + 0.5, "paper beyond the carrier")
        XCTAssertLessThan(printed.column[reach], printed.column[0], "the shadow falls across the edge")
    }

    func testLensSideLightStopsAtTheGate() throws {
        let plain = try develop(scene: 0.18)
        let flashed = try develop(scene: 0.18) { $0.cameraPreflash = 0.1 }
        let diffused = try develop(scene: 0.18) {
            $0.diffusionFilter = DiffusionFilter.preset(.blackProMist, grade: .two)
        }
        let top = plain.margins.top
        XCTAssertNotEqual(flashed.column[top + 15], plain.column[top + 15], "the preflash exposes the frame")
        XCTAssertEqual(flashed.column[2], plain.column[2], accuracy: 1e-4, "but not the film beyond the gate")
        XCTAssertEqual(diffused.column[2], plain.column[2], accuracy: 1e-4,
                       "a diffusion filter's halo stops at the gate too")
    }
}
