import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebLensRequestTests: XCTestCase {
    func testBrowserTableIsTheNativeCorrectionStack() throws {
        for adjustment in [LensAdjustment.neutral,
            LensAdjustment(distortion: -1, vignetting: 1, redCyan: -0.7, blueYellow: 0.4),
            LensAdjustment(distortion: 1, vignetting: -1, redCyan: 1, blueYellow: -1)] {
            let input = try JSONSerialization.data(withJSONObject: ["kind": "lens",
                "adjustment": JSONSerialization.jsonObject(with: JSONEncoder().encode(adjustment))])
            let data = try WebRenderRequest.prepare(input)
            let expected = LensCorrectionStack([adjustment.correction]).resamplingTable()
            XCTAssertEqual(data.count, 4096 * 4)
            let actual: [Float] = data.withUnsafeBytes { bytes in
                (0..<4096).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
            XCTAssertEqual(actual, expected)
        }
    }

    func testInvalidLensAndUnknownRequestsAreRejected() throws {
        for input in [
            #"{"kind":"lens","adjustment":{"distortion":1.01,"vignetting":0,"redCyan":0,"blueYellow":0}}"#,
            #"{"kind":"lens","adjustment":{"distortion":0}}"#,
            #"{"kind":"future"}"#] {
            XCTAssertThrowsError(try WebRenderRequest.prepare(Data(input.utf8)))
        }
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    func testProfilesMatchByNativeMetadataRulesAndPinnedMissingIDsDoNotGuess() throws {
        let profile = LensProfile(id: "synthetic", maker: "Fotufilm", model: "Synthetic 35mm f/2",
            calibrations: [LensCalibration(focalLength: 35, distortion: .poly3(k1: 0.08))])
        var request: [String: Any] = ["kind": "lens-match", "profiles": try object([profile]),
            "shot": try object(LensShot(lensModel: profile.model, lensMaker: profile.maker, focalLength: 35))]
        let matched = try JSONDecoder().decode(LensProfile.self,
            from: WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: request)))
        XCTAssertEqual(matched.id, profile.id)
        request["profileID"] = "missing"
        let missing = try WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(String(decoding: missing, as: UTF8.self), "null")
        request["shot"] = try object(LensShot(lensModel: "Different lens", focalLength: 100))
        request["profileID"] = profile.id
        XCTAssertEqual(try JSONDecoder().decode(LensProfile.self,
            from: WebRenderRequest.prepare(JSONSerialization.data(withJSONObject: request))).id, profile.id)
    }

    func testProfileAmountComposesBeforeManualAdjustmentAndInvalidImportsFail() throws {
        let profile = LensProfile(id: "synthetic", maker: "Fotufilm", model: "Synthetic 35mm f/2",
            calibrations: [LensCalibration(focalLength: 35, distortion: .poly3(k1: 0.08),
                vignetting: .radial(k1: -0.2, k2: 0, k3: 0))])
        let adjustment = LensAdjustment(distortion: 0.3, redCyan: -0.2)
        let request: [String: Any] = ["kind": "lens-plan", "profile": try object(profile),
            "amount": 0.5, "adjustment": try object(adjustment)]
        let decoded = try JSONDecoder().decode(WebLensRequest.self, from: JSONSerialization.data(withJSONObject: request))
        let plan = try decoded.plan()
        XCTAssertEqual(plan.measurement, "profile")
        XCTAssertEqual(plan.table, LensCorrectionStack([
            profile.correction(focalLength: nil, aperture: nil).scaled(by: 0.5), adjustment.correction]).resamplingTable())
        let empty = LensProfile(id: "bad", maker: "", model: "Unmeasured", calibrations: [])
        for profiles in [[empty], [profile, profile]] {
            XCTAssertThrowsError(try WebRenderRequest.prepare(JSONSerialization.data(withJSONObject:
                ["kind": "lens-catalogue", "profiles": try object(profiles)])))
        }
    }

}
