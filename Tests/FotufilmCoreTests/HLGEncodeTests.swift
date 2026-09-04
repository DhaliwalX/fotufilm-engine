#if canImport(CoreImage)
import XCTest
import CoreImage
@testable import FotufilmCore
@testable import FotufilmImaging

final class HLGEncodeTests: XCTestCase {
    private static let oneTenBitCode: Float = 1 / 1023

    func testTheChainBelowTheKneeIsBT2100() {
        let m = HLGTransfer.displayP3ToRec2020
        // BT.2100 Table 5.
        let a: Float = 0.17883277, b: Float = 0.28466892, c: Float = 0.55991073
        let gamma: Float = 1.2

        for probe in [SIMD3<Float>(0.5, 0.5, 0.5), SIMD3(0.4, 0.2, 0.1),
                      SIMD3(0.05, 0.3, 0.6), SIMD3(0.8, 0.8, 0.2)] {
            let wide = SIMD3<Float>(
                m[0] * probe.x + m[1] * probe.y + m[2] * probe.z,
                m[3] * probe.x + m[4] * probe.y + m[5] * probe.z,
                m[6] * probe.x + m[7] * probe.y + m[8] * probe.z)
            let luminance = 0.2627 * wide.x + 0.6780 * wide.y + 0.0593 * wide.z
            let scene = wide * pow(luminance, (1 - gamma) / gamma)
            func oetf(_ value: Float) -> Float {
                let e = min(max(value / PrintEncoding.hdrHeadroom, 0), 1)
                return e <= 1 / 12 ? (3 * e).squareRoot() : a * log(12 * e - b) + c
            }
            let coded = HLGTransfer.encodeRGB(r: probe.x, g: probe.y, b: probe.z)
            XCTAssertEqual(coded.r, oetf(scene.x), accuracy: 1e-5, "red at \(probe)")
            XCTAssertEqual(coded.g, oetf(scene.y), accuracy: 1e-5, "green at \(probe)")
            XCTAssertEqual(coded.b, oetf(scene.z), accuracy: 1e-5, "blue at \(probe)")
        }
    }

    func testDiffuseWhiteLandsOnReferenceWhite() {
        let white = HLGTransfer.encodeRGB(r: 1, g: 1, b: 1)
        for (channel, value) in [("red", white.r), ("green", white.g),
                                 ("blue", white.b)] {
            XCTAssertEqual(value, PrintEncoding.hlgReferenceWhiteSignal,
                           accuracy: 1e-3, "diffuse white in \(channel)")
        }
    }

    func testTheShoulderIsRollingRatherThanClipping() {
        let ceiling = PrintEncoding.hdrDisplayCeiling
        let atCeiling = HLGTransfer.encodeRGB(r: ceiling, g: ceiling, b: ceiling).r
        let farAbove = HLGTransfer.encodeRGB(r: ceiling * 10, g: ceiling * 10,
                                             b: ceiling * 10).r
        XCTAssertLessThan(atCeiling, 0.98,
                          """
                          display light at the ceiling encoded to \(atCeiling), which is what an \
                          unrolled chain gives — the highlight shoulder is not being applied
                          """)
        XCTAssertGreaterThan(atCeiling, 0.85,
                             "the shoulder is compressing far harder than it was calibrated to")
        XCTAssertGreaterThan(farAbove, atCeiling + 1e-3,
                             """
                             light ten times the ceiling encoded no higher than the ceiling \
                             itself, so the shoulder has become a clip
                             """)
        XCTAssertLessThanOrEqual(farAbove, 1,
                                 "the signal ran past full scale at \(farAbove)")
    }

    func testTheTwoHLGRoadsAgreeOnNeutrals() {
        var linear: [Float] = []
        var probes: [Float] = []
        for step in 0...32 {
            let v = Float(step) / 32 * PrintEncoding.hdrDisplayCeiling
            probes.append(v)
            linear += [v, v, v, 1]
        }
        let width = probes.count
        var viaCoreImage = [UInt16](repeating: 0, count: linear.count)
        var viaConverter = [UInt16](repeating: 0, count: linear.count)
        linear.withUnsafeBufferPointer { source in
            viaCoreImage.withUnsafeMutableBufferPointer { out in
                PrintEncoding.encodeRows(source, rows: 0..<1, width: width,
                                         into: out, transfer: .hlg)
            }
            viaConverter.withUnsafeMutableBufferPointer { out in
                PrintEncoding.encodeRows(source, rows: 0..<1, width: width,
                                         into: out,
                                         converter: FilmOutputConversion.rec2020HLG)
            }
        }
        var worst: Float = 0
        var worstAt = 0
        for index in 0..<linear.count where index % 4 != 3 {
            let delta = abs(Float(viaCoreImage[index]) - Float(viaConverter[index])) / 65535
            if delta > worst { worst = delta; worstAt = index }
        }
        XCTAssertLessThanOrEqual(
            worst, Self.oneTenBitCode,
            """
            the two HLG roads disagree by \(worst * 1023) 10-bit codes on the neutral ramp, at \
            display light \(probes[worstAt / 4]) — neutrals are the one place they had agreed
            """)
    }

    func testTheOutputConverterReadsTheFourthChannelAsAGain() {
        // Doubling by the gain must reach the same light as the pixel already doubled, and a
        // fourth channel below one must not darken anything.
        let linear: [Float] = [0.2, 0.2, 0.2, 2,
                               0.4, 0.4, 0.4, 1,
                               0.4, 0.4, 0.4, 0.25]
        var out = [UInt16](repeating: 0, count: linear.count)
        linear.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                PrintEncoding.encodeRows(source, rows: 0..<1, width: 3,
                                         into: destination,
                                         converter: FilmOutputConversion.rec2020HLG)
            }
        }
        XCTAssertEqual(out[0], out[4],
                       "a gain of 2 did not reach the same light as twice the value")
        XCTAssertEqual(out[8], out[4],
                       "a fourth channel below one changed the encoded light")
        for pixel in 0..<3 {
            XCTAssertEqual(out[pixel * 4 + 3], 65535,
                           "pixel \(pixel) left the converter transparent")
        }
    }
    func testTheEnginesTwoSpellingsOfTheChainAgree() {
        let ceiling = PrintEncoding.hdrDisplayCeiling
        var linear: [Float] = []
        var probes: [SIMD3<Float>] = []
        for step in 1...8 {
            let v = Float(step) / 8 * ceiling
            for probe in [SIMD3<Float>(v, 0, 0), SIMD3(0, v, 0), SIMD3(0, 0, v),
                          SIMD3(v, v * 0.35, v * 0.08), SIMD3(v * 0.08, v, v * 0.35),
                          SIMD3(v * 0.35, v * 0.08, v)] {
                probes.append(probe)
                linear += [probe.x, probe.y, probe.z, 1]
            }
        }
        var viaConverter = [UInt16](repeating: 0, count: linear.count)
        linear.withUnsafeBufferPointer { source in
            viaConverter.withUnsafeMutableBufferPointer { out in
                PrintEncoding.encodeRows(source, rows: 0..<1, width: probes.count,
                                         into: out,
                                         converter: FilmOutputConversion.rec2020HLG)
            }
        }
        var worst: Float = 0
        var worstProbe = SIMD3<Float>()
        for (index, probe) in probes.enumerated() {
            let expected = HLGTransfer.encodeRGB(r: probe.x, g: probe.y, b: probe.z)
            for (channel, value) in [expected.r, expected.g, expected.b].enumerated() {
                let actual = Float(viaConverter[index * 4 + channel]) / 65535
                let delta = abs(actual - value)
                if delta > worst { worst = delta; worstProbe = probe }
            }
        }
        XCTAssertLessThanOrEqual(
            worst, Self.oneTenBitCode,
            """
            the engine's two spellings of the HLG chain disagree by \(worst * 1023) 10-bit \
            codes at \(worstProbe). They are the same function written twice; they have drifted.
            """)
    }
}
#endif
