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
        let landscape = still.margins(photoWidth: 3600, photoHeight: 2400, pixelsPerMM: 100)
        XCTAssertEqual(landscape, .init(left: 100, right: 100, top: 70, bottom: 70))
        let portrait = still.margins(photoWidth: 2400, photoHeight: 3600, pixelsPerMM: 100)
        XCTAssertEqual(portrait, .init(left: 70, right: 70, top: 100, bottom: 100))
        let square = still.margins(photoWidth: 2400, photoHeight: 2400, pixelsPerMM: 100)
        XCTAssertEqual(square, landscape, "a square crop keeps the film's orientation")
    }

    func testGatePenumbraIsTheShareOfTheLensPupilPastTheEdge() {
        let radius = UnexposedEdge.gateSeparationMM / (2 * UnexposedEdge.referenceFNumber)
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
        XCTAssertEqual(gate[4], UnexposedEdge.gateRadiusMM * 10, accuracy: 1e-6)
    }

    /// Develops a uniform photograph of `scene` light on a larger piece of film and returns the
    /// red record of the middle column: the band above the photograph, then its top rows.
    private func develop(scene: Float, _ configure: (inout FotufilmEngine.Options) -> Void = { _ in })
        throws -> (column: [Float], margins: UnexposedEdge.Margins) {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.localTone = false
        configure(&options)
        let width = 720, height = 480
        let margins = try XCTUnwrap(UnexposedEdge.Geometry.preset("120"))
            .margins(photoWidth: width, photoHeight: height,
                     pixelsPerMM: options.pixelsPerMM(width: width, height: height))
        options.unexposedEdge = .init(margins: margins)
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
