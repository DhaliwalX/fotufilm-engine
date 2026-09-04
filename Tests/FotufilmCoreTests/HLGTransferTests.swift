import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging

final class HLGTransferTests: XCTestCase {
    func testSceneLightInvertsTheEncode() {
        for step in 0...200 {
            let signal = Float(step) / 200
            let scene = PrintEncoding.hlgSceneLight(at: signal)
            let back = PrintEncoding.encodeHLG(scene)
            XCTAssertEqual(back, signal, accuracy: 1e-5,
                           "HLG does not round trip at signal \(signal)")
        }
    }

    func testWhiteSurvivesTheGamutMatrix() {
        for (name, m) in [("rec2020ToDisplayP3", HLGTransfer.rec2020ToDisplayP3),
                          ("displayP3ToRec2020", HLGTransfer.displayP3ToRec2020)] {
            for row in 0..<3 {
                let sum = m[row * 3] + m[row * 3 + 1] + m[row * 3 + 2]
                XCTAssertEqual(sum, 1, accuracy: 1e-6,
                               "row \(row) of \(name) does not preserve white")
            }
        }
    }

    func testGamutMatricesRoundTrip() {
        let there = HLGTransfer.rec2020ToDisplayP3
        let back = HLGTransfer.displayP3ToRec2020
        for column in 0..<3 {
            for row in 0..<3 {
                var sum: Float = 0
                for k in 0..<3 { sum += back[row * 3 + k] * there[k * 3 + column] }
                XCTAssertEqual(sum, row == column ? 1 : 0, accuracy: 1e-6,
                               "element (\(row), \(column)) of the round trip")
            }
        }
    }

    func testReferenceWhiteArrivesAsDiffuseWhite() {
        let luma = 64 + PrintEncoding.hlgReferenceWhiteSignal * 876
        let (r, g, b) = HLGTransfer.decode(luma: luma, cb: 512, cr: 512)
        XCTAssertEqual(r, 1, accuracy: 2e-3)
        XCTAssertEqual(g, 1, accuracy: 2e-3)
        XCTAssertEqual(b, 1, accuracy: 2e-3)
    }

    func testEndpointsOfTheCaptureRange() {
        let (r, g, b) = HLGTransfer.decode(luma: 64, cb: 512, cr: 512)
        XCTAssertEqual(r, 0, accuracy: 1e-5)
        XCTAssertEqual(g, 0, accuracy: 1e-5)
        XCTAssertEqual(b, 0, accuracy: 1e-5)

        let peak = HLGTransfer.decode(luma: 940, cb: 512, cr: 512)
        XCTAssertEqual(peak.0, PrintEncoding.hdrHeadroom, accuracy: 5e-3,
                       "peak signal should reach the scene-light headroom")
    }

    func testTheOOTFFixesDiffuseWhite() {
        let white = HLGTransfer.openToOptical(r: 1, g: 1, b: 1)
        XCTAssertEqual(white.r, 1, accuracy: 1e-6)
        XCTAssertEqual(white.g, 1, accuracy: 1e-6)
        XCTAssertEqual(white.b, 1, accuracy: 1e-6)
        let grey = HLGTransfer.openToOptical(r: 0.18, g: 0.18, b: 0.18)
        XCTAssertLessThan(grey.r, 0.18)
        for value in [Float(0.02), 0.18, 0.5, 1, 2.5] {
            let there = HLGTransfer.openToOptical(r: value, g: value, b: value)
            let back = HLGTransfer.opticalToOpen(r: there.r, g: there.g, b: there.b)
            XCTAssertEqual(back.r, value, accuracy: max(1e-4, value * 1e-3),
                           "the OOTF does not invert at \(value)")
        }
        let colour = HLGTransfer.openToOptical(r: 0.4, g: 0.2, b: 0.1)
        XCTAssertEqual(colour.r / colour.g, 2, accuracy: 1e-5)
        XCTAssertEqual(colour.g / colour.b, 2, accuracy: 1e-5)
    }

    func testPreviewDisplayLightIsThePrintUpToTheKnee() {
        for value in [Float(0.005), 0.02, 0.18, 0.5, 0.89] {
            let shown = HLGTransfer.previewDisplayLight(
                r: value, g: value, b: value, ceiling: 2)
            XCTAssertEqual(shown.r, value, accuracy: 1e-6,
                           "the presenter retouched a midtone at \(value)")
        }
        var previous: Float = 0
        for value in [Float(0.95), 1, 2, 4, 100] {
            let shown = HLGTransfer.previewDisplayLight(
                r: value, g: value, b: value, ceiling: 2)
            XCTAssertGreaterThan(shown.r, previous,
                                 "the display shoulder is not monotonic")
            XCTAssertLessThan(shown.r, 2,
                              "a highlight escaped the screen's headroom")
            previous = shown.r
        }
        let sdr = HLGTransfer.previewDisplayLight(r: 2, g: 2, b: 2, ceiling: 1)
        XCTAssertEqual(sdr.r, PrintEncoding.hdrShoulder(2, ceiling: 1),
                       accuracy: 1e-6)
        let capped = HLGTransfer.previewDisplayLight(
            r: 4, g: 4, b: 4, ceiling: 100)
        let atCeiling = HLGTransfer.previewDisplayLight(
            r: 4, g: 4, b: 4, ceiling: PrintEncoding.hdrDisplayCeiling)
        XCTAssertEqual(capped.r, atCeiling.r, accuracy: 1e-6)
    }

    func testVideoExposureTrimRecentresTheFeed() {
        XCTAssertLessThan(HLGTransfer.videoExposureTrim, 1)
        XCTAssertGreaterThan(HLGTransfer.videoExposureTrim, 0.85)
    }

    func testHDRShoulderPreservesSaturatedHighlightHue() {
        let source = SIMD3<Float>(4, 1, 0.2)
        let rolled = HLGTransfer.hdrShoulderPreservingHue(source)
        XCTAssertEqual(rolled.x / rolled.y, source.x / source.y,
                       accuracy: 1e-6)
        XCTAssertEqual(rolled.y / rolled.z, source.y / source.z,
                       accuracy: 1e-6)
        XCTAssertLessThan(rolled.x, PrintEncoding.hdrDisplayCeiling)

        let shown = HLGTransfer.previewDisplayLight(
            r: source.x, g: source.y, b: source.z, ceiling: 2)
        XCTAssertEqual(shown.r / shown.g, source.x / source.y,
                       accuracy: 1e-5)
        XCTAssertEqual(shown.g / shown.b, source.y / source.z,
                       accuracy: 1e-5)
    }

    func testWideGamutFitPreservesLuminanceAndHueDirection() {
        let source = SIMD3<Float>(PrintEncoding.hdrHeadroom, 0, 0)
        let m = HLGTransfer.rec2020ToDisplayP3
        let raw = SIMD3<Float>(
            m[0] * source.x + m[1] * source.y + m[2] * source.z,
            m[3] * source.x + m[4] * source.y + m[5] * source.z,
            m[6] * source.x + m[7] * source.y + m[8] * source.z)
        let mapped = HLGTransfer.mapRec2020ToDisplayP3(source)
        for channel in 0..<3 {
            XCTAssertGreaterThanOrEqual(mapped[channel], 0)
            XCTAssertLessThanOrEqual(mapped[channel], PrintEncoding.hdrHeadroom)
        }
        let weights = HLGTransfer.displayP3Luminance
        let rawY = raw.x * weights.x + raw.y * weights.y + raw.z * weights.z
        let mappedY = mapped.x * weights.x
            + mapped.y * weights.y + mapped.z * weights.z
        XCTAssertEqual(mappedY, rawY, accuracy: 2e-5)

        let neutral = SIMD3<Float>(repeating: rawY)
        let rawDelta = raw - neutral
        let mappedDelta = mapped - neutral
        let scale = mappedDelta.x / rawDelta.x
        XCTAssertEqual(mappedDelta.y, rawDelta.y * scale, accuracy: 2e-5)
        XCTAssertEqual(mappedDelta.z, rawDelta.z * scale, accuracy: 2e-5)
    }

    func testTheTwoGamutMatricesInvertEachOther() {
        let forward = HLGTransfer.rec2020ToDisplayP3
        let back = HLGTransfer.displayP3ToRec2020
        for row in 0..<3 {
            for column in 0..<3 {
                var product: Float = 0
                for k in 0..<3 {
                    let left: Float = back[row * 3 + k]
                    let right: Float = forward[k * 3 + column]
                    product += left * right
                }
                XCTAssertEqual(product, row == column ? 1 : 0, accuracy: 1e-5,
                               "the gamut matrices do not invert at \(row),\(column)")
            }
            let sum = back[row * 3] + back[row * 3 + 1] + back[row * 3 + 2]
            XCTAssertEqual(sum, 1, accuracy: 5e-4,
                           "row \(row) of the record matrix does not preserve white")
        }
    }

    func testPrintSurvivesTheRecordingRoundTrip() {
        for step in 0...18 {
            let value = Float(step) / 20
            let signal = HLGTransfer.encode(r: value, g: value, b: value)
            let (r, g, b) = HLGTransfer.decode(
                luma: signal.y * 876 + 64,
                cb: signal.u * 896 + 512,
                cr: signal.v * 896 + 512)
            let displayed = HLGTransfer.openToOptical(r: r, g: g, b: b)
            XCTAssertEqual(displayed.r, value, accuracy: 2e-3,
                           "red drifted at \(value)")
            XCTAssertEqual(displayed.g, value, accuracy: 2e-3,
                           "green drifted at \(value)")
            XCTAssertEqual(displayed.b, value, accuracy: 2e-3,
                           "blue drifted at \(value)")
        }
    }

    func test420ChromaIsTheAverageOfTheEncodedBlock() {
        let pixels = (
            SIMD3<Float>(0.8, 0.1, 0.1),
            SIMD3<Float>(0.1, 0.7, 0.2),
            SIMD3<Float>(0.1, 0.2, 0.9),
            SIMD3<Float>(0.6, 0.5, 0.1))
        let individual = [pixels.0, pixels.1, pixels.2, pixels.3].map {
            HLGTransfer.encode(r: $0.x, g: $0.y, b: $0.z)
        }
        let block = HLGTransfer.encode420(
            topLeft: pixels.0, topRight: pixels.1,
            bottomLeft: pixels.2, bottomRight: pixels.3)
        for index in 0..<4 {
            XCTAssertEqual(block.luma[index], individual[index].y,
                           accuracy: 1e-7)
        }
        let expectedU = individual.reduce(Float(0)) { $0 + $1.u } / 4
        let expectedV = individual.reduce(Float(0)) { $0 + $1.v } / 4
        XCTAssertEqual(block.u, expectedU, accuracy: 1e-7)
        XCTAssertEqual(block.v, expectedV, accuracy: 1e-7)
        XCTAssertNotEqual(block.u, individual[0].u, accuracy: 1e-3,
                          "chroma still comes from the top-left pixel")
        XCTAssertNotEqual(block.v, individual[0].v, accuracy: 1e-3,
                          "chroma still comes from the top-left pixel")
    }

    func testCaptureToPrintRoundTripsBelowTheKnee() {
        for step in 0...40 {
            let signal = Float(step) / 40 * PrintEncoding.hlgReferenceWhiteSignal
            let luma = 64 + signal * 876
            let (r, _, _) = HLGTransfer.decode(luma: luma, cb: 512, cr: 512)
            guard r <= 0.9 else { continue }
            let back = PrintEncoding.encodeHLG(r / PrintEncoding.hdrHeadroom)
            XCTAssertEqual(back, signal, accuracy: 2e-3,
                           "capture at signal \(signal) came back as \(back)")
        }
    }
}
