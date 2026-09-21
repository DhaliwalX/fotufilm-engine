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
}
