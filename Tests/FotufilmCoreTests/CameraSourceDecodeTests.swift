import XCTest
@testable import FotufilmCore

final class CameraSourceDecodeTests: XCTestCase {

    // MARK: Forward curves, restated from the papers

    private func appleLogEncode(_ reflectance: Double) -> Double {
        let r0 = -0.05641088, c = 47.28711236
        let beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945
        if reflectance >= 0.01 {
            return gamma * log2(reflectance + beta) + delta
        }
        return c * (reflectance - r0) * (reflectance - r0)
    }

    private func slog3Encode(_ reflectance: Double) -> Double {
        let code: Double
        if reflectance >= 0.01125000 {
            code = 420 + log10((reflectance + 0.01) / 0.19) * 261.5
        } else {
            code = reflectance * (171.2102946929 - 95) / 0.01125 + 95
        }
        return code / 1023
    }

    private func slog2Encode(_ reflectance: Double) -> Double {
        let x = reflectance / (0.9 * 219.0 / 155.0)
        let y: Double
        if x > 0 {
            y = 0.432699 * log10(x + 0.037584) + 0.616596 + 0.03
        } else {
            y = 5 * x + 0.030001222851889303
        }
        return (y * 876 + 64) / 1023
    }

    private func hlgEncode(_ reflectance: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let referenceLight = (exp((0.75 - c) / a) + b) / 12
        let sceneLight = reflectance / 0.9 * referenceLight
        let signal = sceneLight <= 1.0 / 12
            ? (3 * sceneLight).squareRoot()
            : a * log(12 * sceneLight - b) + c
        return signal
    }

    private func flogEncode(_ reflectance: Double) -> Double {
        let a = 0.555556, b = 0.009468, c = 0.344676, d = 0.790453
        let e = 8.735631, f = 0.092864, cut = 0.00089
        return reflectance >= cut
            ? c * log10(a * reflectance + b) + d
            : e * reflectance + f
    }

    private func flog2Encode(_ reflectance: Double) -> Double {
        let a = 5.555556, b = 0.064829, c = 0.245281, d = 0.384316
        let e = 8.799461, f = 0.092864, cut = 0.000889
        return reflectance >= cut
            ? c * log10(a * reflectance + b) + d
            : e * reflectance + f
    }

    private func encode(_ curve: CameraLogCurve, _ reflectance: Double) -> Float {
        switch curve {
        case .appleLog: return Float(appleLogEncode(reflectance))
        case .sLog3: return Float(slog3Encode(reflectance))
        case .sLog2: return Float(slog2Encode(reflectance))
        case .hlg: return Float(hlgEncode(reflectance))
        case .fLog: return Float(flogEncode(reflectance))
        case .fLog2: return Float(flog2Encode(reflectance))
        }
    }

    private func ceiling(_ curve: CameraLogCurve) -> Double {
        Double(curve.linear(1))
    }

    // MARK: Inverse exactness

    func testSLog3MidGreyAnchor() {
        XCTAssertEqual(CameraLogCurve.slog3ToLinear(420.0 / 1023.0), 0.18,
                       accuracy: 1e-6)
        // Code 95 is S-Log3's zero.
        XCTAssertEqual(CameraLogCurve.slog3ToLinear(95.0 / 1023.0), 0,
                       accuracy: 1e-6)
    }

    /// The anchor table Apple prints in the Apple Log 2 white paper (September 2025), which
    /// states the curve is the Apple Log transfer function unchanged: float signal and 10-bit
    /// full-range code for 0%, 18%, 90%, and 1200% scene reflection.
    func testAppleLogPublishedAnchors() {
        let anchors: [(float: Float, code: Float, reflectance: Float)] = [
            (0.150477, 154, 0), (0.488272, 500, 0.18),
            (0.681686, 697, 0.9), (1.0, 1023, 12),
        ]
        for anchor in anchors {
            XCTAssertEqual(AppleLogCurve.linear(anchor.float), anchor.reflectance,
                           accuracy: 1e-5 + anchor.reflectance * 1e-5,
                           "float \(anchor.float)")
            // The 10-bit column is the float column rounded, so it lands within a code's width.
            XCTAssertEqual(AppleLogCurve.linear(anchor.code / 1023), anchor.reflectance,
                           accuracy: 1e-4 + anchor.reflectance * 5e-3,
                           "code \(anchor.code)")
        }
    }

    func testFujifilmLogPublishedAnchors() {
        XCTAssertEqual(CameraLogCurve.flogToLinear(95.0 / 1023.0), 0,
                       accuracy: 2e-5)
        XCTAssertEqual(CameraLogCurve.flogToLinear(470.0 / 1023.0), 0.18,
                       accuracy: 5e-4)
        XCTAssertEqual(CameraLogCurve.flogToLinear(705.0 / 1023.0), 0.9,
                       accuracy: 3e-3)
        XCTAssertEqual(CameraLogCurve.flog2ToLinear(95.0 / 1023.0), 0,
                       accuracy: 2e-5)
        XCTAssertEqual(CameraLogCurve.flog2ToLinear(400.0 / 1023.0), 0.18,
                       accuracy: 5e-4)
        XCTAssertEqual(CameraLogCurve.flog2ToLinear(570.0 / 1023.0), 0.9,
                       accuracy: 3e-3)
    }

    func testDecodeInvertsPublishedEncode() {
        let reflectances = [0.02, 0.05, 0.09, 0.18, 0.45, 0.9, 1.8, 3.0, 6.0]
        for curve in CameraLogCurve.allCases {
            for reflectance in reflectances
            where reflectance <= ceiling(curve) {
                let decoded = curve.linear(encode(curve, reflectance))
                XCTAssertEqual(Double(decoded), reflectance,
                               accuracy: reflectance * 2e-4,
                               "\(curve) at \(reflectance)")
            }
        }
    }

    func testHLGAnchorsAndDeclaredHeadroom() {
        XCTAssertEqual(CameraLogCurve.hlgToLinear(0.75),
                       0.9, accuracy: 1e-5)
        XCTAssertEqual(CameraLogCurve.hlgToLinear(1),
                       0.9 * HLGSceneTransfer.headroom, accuracy: 1e-4)
        XCTAssertEqual(HLGSceneTransfer.headroom, 3.7745, accuracy: 1e-3)
        XCTAssertNil(CameraLogEncoding.appleLog.declaredHeadroom)
        XCTAssertNil(CameraLogEncoding.appleLog2.declaredHeadroom)
        XCTAssertNil(CameraLogEncoding.slog3.declaredHeadroom)
        XCTAssertNil(CameraLogEncoding.flog.declaredHeadroom)
        XCTAssertNil(CameraLogEncoding.flog2.declaredHeadroom)
        XCTAssertNil(CameraLogEncoding.flog2C.declaredHeadroom)
        XCTAssertEqual(CameraLogEncoding.hlg.declaredHeadroom,
                       HLGSceneTransfer.headroom)
    }

    // MARK: Gamut matrices

    func testGamutMatricesPreserveWhite() {
        let gamuts: [(String, CameraGamut)] = [
            ("Rec.2020", .rec2020), ("S-Gamut3.Cine", .sGamut3Cine),
            ("S-Gamut", .sGamut), ("F-Gamut C", .fGamutC),
            ("Display P3", .displayP3),
        ]
        for (name, gamut) in gamuts {
            let m = gamut.toDisplayP3
            for row in 0..<3 {
                let sum = m[row * 3] + m[row * 3 + 1] + m[row * 3 + 2]
                XCTAssertEqual(sum, 1, accuracy: 1e-9, "\(name) row \(row)")
            }
        }
    }

    func testDisplayP3MatrixIsIdentity() {
        let m = CameraGamut.displayP3.toDisplayP3
        let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for i in 0..<9 {
            XCTAssertEqual(m[i], identity[i], accuracy: 1e-9, "element \(i)")
        }
    }

    // MARK: The contract types travel

    func testSourceLightRoundTripsThroughJSON() throws {
        let light = SourceLight(
            domain: .sceneLinear(colorSpace: .displayP3Linear),
            transferFunction: .appleLog,
            primaries: CameraGamut.rec2020.primaries,
            camera: CameraIdentity(make: "Apple", model: "iPhone 15 Pro"),
            asShotIlluminant: WhiteBalance(kelvin: 5600, tint: 3),
            exposure: ExposureMetadata(time: 1 / 48, aperture: 1.8, speed: 400),
            normalization: .sceneReflectance)
        let decoded = try JSONDecoder().decode(
            SourceLight.self, from: JSONEncoder().encode(light))
        XCTAssertEqual(decoded, light)
        let layer = SourceLight(domain: .filmLayerExposure(stockID: "k200"),
                                transferFunction: .linear)
        let layerDecoded = try JSONDecoder().decode(
            SourceLight.self, from: JSONEncoder().encode(layer))
        XCTAssertEqual(layerDecoded.domain, .filmLayerExposure(stockID: "k200"))
    }

    func testCameraEncodingDeclaresTheEngineWorkingSpace() {
        for encoding in CameraLogEncoding.allCases {
            XCTAssertEqual(
                encoding.sourceLight.domain,
                .sceneLinear(colorSpace: .rec2020Linear),
                "\(encoding) declared a different space from its converter output")
        }
    }

    func testCameraEncodingTable() {
        XCTAssertEqual(CameraLogEncoding.appleLog.curve, .appleLog)
        XCTAssertEqual(CameraLogEncoding.appleLog.gamut, .rec2020)
        XCTAssertEqual(CameraLogEncoding.appleLog2.curve, .appleLog)
        XCTAssertEqual(CameraLogEncoding.appleLog2.gamut, .appleWideGamut)
        XCTAssertEqual(CameraLogEncoding.appleLog2.transferFunction, .appleLog)
        XCTAssertEqual(CameraLogEncoding.appleLog2.sourceLight.primaries,
                       CameraGamut.appleWideGamut.primaries)
        XCTAssertEqual(CameraLogEncoding.slog3Cine.curve, .sLog3)
        XCTAssertEqual(CameraLogEncoding.slog3Cine.gamut, .sGamut3Cine)
        XCTAssertEqual(CameraLogEncoding.slog3.curve, .sLog3)
        XCTAssertEqual(CameraLogEncoding.slog3.gamut, .sGamut)
        XCTAssertEqual(CameraLogEncoding.slog2.curve, .sLog2)
        XCTAssertEqual(CameraLogEncoding.slog2.gamut, .sGamut)
        XCTAssertEqual(CameraLogEncoding.flog.curve, .fLog)
        XCTAssertEqual(CameraLogEncoding.flog.gamut, .fGamut)
        XCTAssertEqual(CameraLogEncoding.flog2.curve, .fLog2)
        XCTAssertEqual(CameraLogEncoding.flog2.gamut, .fGamut)
        XCTAssertEqual(CameraLogEncoding.flog2C.curve, .fLog2)
        XCTAssertEqual(CameraLogEncoding.flog2C.gamut, .fGamutC)
        XCTAssertEqual(CameraLogEncoding.hlg.curve, .hlg)
        XCTAssertEqual(CameraLogEncoding.hlg.gamut, .rec2020)
    }

    /// Apple Wide Gamut as published for Apple Log 2 (and carried into the ACES CSC transforms
    /// and the OCIO studio config), solved against Rec.2020 with D65 on both sides.
    func testAppleWideGamutMatchesThePublishedPrimaries() {
        let primaries = CameraGamut.appleWideGamut.primaries
        XCTAssertEqual(primaries.rx, 0.725); XCTAssertEqual(primaries.ry, 0.301)
        XCTAssertEqual(primaries.gx, 0.221); XCTAssertEqual(primaries.gy, 0.814)
        XCTAssertEqual(primaries.bx, 0.068); XCTAssertEqual(primaries.by, -0.076)

        let expected: [Double] = [
            1.028100938, 0.098978818, -0.127079756,
            0.002520342, 1.170849643, -0.173369985,
            -0.022087573, -0.064050383, 1.086137957,
        ]
        let matrix = CameraGamut.appleWideGamut.toRec2020
        for (index, value) in expected.enumerated() {
            XCTAssertEqual(matrix[index], value, accuracy: 1e-8, "element \(index)")
        }
        // D65 to D65: the recorded white is the working white.
        for row in 0..<3 {
            XCTAssertEqual(matrix[row * 3] + matrix[row * 3 + 1] + matrix[row * 3 + 2],
                           1, accuracy: 1e-12)
        }
        // The recorded blue and red lie outside Rec.2020, which is the point of the gamut.
        XCTAssertLessThan(matrix[2], 0)
        XCTAssertLessThan(matrix[5], 0)
        XCTAssertLessThan(matrix[6], 0)
    }
}
