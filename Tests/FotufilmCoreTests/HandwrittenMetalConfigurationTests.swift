import Foundation
import XCTest
@testable import FotufilmCore
#if canImport(Metal)
@testable import FotufilmMetal
#endif

final class HandwrittenMetalConfigurationTests: XCTestCase {
    func testReleaseMetallibConfigurationMatchesSwiftAuthorities() throws {
        let definitions = try releaseDefinitions()
        let offsets: [String: Int] = [
            "FOTUFILM_CFG_CURVE_SECONDARY": FilmEngineInvocation.curveSecondaryOffset,
            "FOTUFILM_CFG_COUPLER_RELEASE_GAMMA":
                FilmEngineInvocation.couplerReleaseGammaOffset,
            "FOTUFILM_CFG_DONOR_RELEASE_GAMMA":
                FilmEngineInvocation.donorReleaseGammaOffset,
            "FOTUFILM_CFG_DONOR_CURVE": FilmEngineInvocation.donorCurveOffset,
            "FOTUFILM_CFG_DONOR_RELEASE": FilmEngineInvocation.donorReleaseOffset,
            "FOTUFILM_CFG_EXPOSURE_GAIN": FilmEngineInvocation.exposureGainOffset,
            "FOTUFILM_CFG_WHITE_BALANCE": FilmEngineInvocation.whiteBalanceOffset,
            "FOTUFILM_CFG_SCENE_ADJUST": FilmEngineInvocation.sceneAdjustOffset,
            "FOTUFILM_CFG_GRADE": FilmEngineInvocation.gradeOffset,
            "FOTUFILM_CFG_FRAME_SIZE": FilmEngineInvocation.frameSizeOffset,
            "FOTUFILM_CFG_TONE_GRID_SIZE": FilmEngineInvocation.toneGridSizeOffset,
            "FOTUFILM_CFG_TONE_GRID_A": FilmEngineInvocation.toneGridAOffset,
            "FOTUFILM_CFG_TONE_GRID_B": FilmEngineInvocation.toneGridBOffset,
            "FOTUFILM_CFG_PAPER_RED": FilmEngineInvocation.paperRedOffset,
            "FOTUFILM_CFG_PAPER_BLUE": FilmEngineInvocation.paperBlueOffset,
            "FOTUFILM_CFG_PAPER_MIDPOINT_RED":
                FilmEngineInvocation.paperMidpointRedOffset,
            "FOTUFILM_CFG_PAPER_MIDPOINT_BLUE":
                FilmEngineInvocation.paperMidpointBlueOffset,
        ]
        for (name, expected) in offsets {
            XCTAssertEqual(Int(definitions[name] ?? ""), expected, name)
        }

#if canImport(Metal)
        let tableSizes: [String: Int] = [
            "FOTUFILM_POINTWISE_TRANSFER_SAMPLES":
                HandwrittenMetalFilmRenderer.transferSamples,
            "FOTUFILM_POINTWISE_DECODE_SAMPLES":
                HandwrittenMetalFilmRenderer.decodeSamples,
            "FOTUFILM_HIERARCHICAL_DECODE_SAMPLES":
                HandwrittenMetalHierarchicalFrameRenderer.decodeSamples,
            "FOTUFILM_ENDPOINT_CURVE_SAMPLES":
                HandwrittenMetalFrameEndpoints.curveSamples,
            "FOTUFILM_ENDPOINT_TRANSFER_SAMPLES":
                HandwrittenMetalFrameEndpoints.transferSamples,
            "FOTUFILM_MEASUREMENT_REDUCTION_THREADS":
                HandwrittenMetalGlobalMeasurements.reductionThreads,
            "FOTUFILM_MEASUREMENT_FLARE_ITEMS":
                HandwrittenMetalGlobalMeasurements.flareItemsPerThread,
            "FOTUFILM_HEAD_DECODE_SAMPLES":
                HandwrittenMetalSpectralHead.decodeSamples,
            "FOTUFILM_CAMERA_DECODE_SAMPLES":
                HandwrittenMetalCameraPassThrough.decodeSamples,
        ]
        for (name, expected) in tableSizes {
            XCTAssertEqual(Int(definitions[name] ?? ""), expected, name)
        }
#endif

        let scalars: [String: Float] = [
            "FOTUFILM_HLG_A": HLGSceneTransfer.a,
            "FOTUFILM_HLG_B": HLGSceneTransfer.b,
            "FOTUFILM_HLG_C": HLGSceneTransfer.c,
            "FOTUFILM_APPLE_LOG_R0": AppleLogCurve.r0,
            "FOTUFILM_APPLE_LOG_C": AppleLogCurve.c,
            "FOTUFILM_APPLE_LOG_BETA": AppleLogCurve.beta,
            "FOTUFILM_APPLE_LOG_GAMMA": AppleLogCurve.gamma,
            "FOTUFILM_APPLE_LOG_DELTA": AppleLogCurve.delta,
            "FOTUFILM_APPLE_LOG_TOE_SIGNAL": AppleLogCurve.toeSignal,
            "FOTUFILM_DELIVERY_HLG_HEADROOM": HLGSceneTransfer.headroom,
            "FOTUFILM_DELIVERY_HLG_DISPLAY_CEILING":
                pow(HLGSceneTransfer.headroom, 1.2),
            "FOTUFILM_DELIVERY_HLG_GAMMA": 1.2,
        ]
        for (name, expected) in scalars {
            XCTAssertEqual(try floatDefinition(name, in: definitions), expected,
                           accuracy: 2e-6, name)
        }

        let transforms: [(String, (SIMD3<Float>) -> SIMD3<Float>)] = [
            ("FOTUFILM_DELIVERY_P3_TO_2020_", ColorScience.linearDisplayP3ToRec2020),
            ("FOTUFILM_DELIVERY_P3_TO_709_", ColorScience.linearDisplayP3ToSRGB),
        ]
        for (prefix, transform) in transforms {
            let red = transform(SIMD3(1, 0, 0))
            let green = transform(SIMD3(0, 1, 0))
            let blue = transform(SIMD3(0, 0, 1))
            let rowMajor = [
                red.x, green.x, blue.x,
                red.y, green.y, blue.y,
                red.z, green.z, blue.z,
            ]
            for (index, expected) in rowMajor.enumerated() {
                XCTAssertEqual(
                    try floatDefinition("\(prefix)\(index)", in: definitions),
                    expected, accuracy: 2e-6, "\(prefix)\(index)")
            }
        }
    }

    private func releaseDefinitions() throws -> [String: String] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repository.appendingPathComponent(
            "tools/build-handwritten-metallib.sh")
        let source = try String(contentsOf: script, encoding: .utf8)
        var result: [String: String] = [:]
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-D"),
                  let token = trimmed.split(whereSeparator: \Character.isWhitespace).first,
                  let separator = token.firstIndex(of: "=")
            else { continue }
            let name = String(token[token.index(token.startIndex, offsetBy: 2)..<separator])
            result[name] = String(token[token.index(after: separator)...])
        }
        return result
    }

    private func floatDefinition(
        _ name: String, in definitions: [String: String]
    ) throws -> Float {
        let raw = try XCTUnwrap(definitions[name], name)
        let number = raw.hasSuffix("f") ? String(raw.dropLast()) : raw
        return try XCTUnwrap(Float(number), name)
    }
}
