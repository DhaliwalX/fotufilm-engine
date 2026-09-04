import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging

final class VideoSourceColorTests: XCTestCase {
    private func pqSignal(nits: Float) -> Float {
        let m1: Float = 2610.0 / 16384.0
        let m2: Float = 2523.0 / 32.0
        let c1: Float = 3424.0 / 4096.0
        let c2: Float = 2413.0 / 128.0
        let c3: Float = 2392.0 / 128.0
        let light = pow(min(max(nits / 10_000, 0), 1), m1)
        return pow((c1 + c2 * light) / (1 + c3 * light), m2)
    }

    func testSDRDisplayP3BecomesLinearRec2020() {
        let converted = VideoSourceColor.colorManagedSDR.linearRec2020(
            SIMD3<Float>(1, 0, 0))
        let expected = ColorScience.linearDisplayP3ToRec2020(SIMD3(1, 0, 0))
        XCTAssertEqual(converted.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(converted.y, expected.y, accuracy: 1e-6)
        XCTAssertEqual(converted.z, expected.z, accuracy: 1e-6)
    }

    func testHLGIsInverseOETFSceneLightWithoutDisplayOOTF() {
        let source = VideoSourceColor(transfer: .hlg, primaries: .rec2020)
        let white = source.linearRec2020(SIMD3(
            repeating: HLGSceneTransfer.diffuseWhiteSignal))
        XCTAssertEqual(white.x, 1, accuracy: 1e-5)
        XCTAssertEqual(white.y, 1, accuracy: 1e-5)
        XCTAssertEqual(white.z, 1, accuracy: 1e-5)

        let greySignal = PrintEncoding.encodeHLG(
            0.18 / HLGSceneTransfer.headroom)
        let grey = source.linearRec2020(SIMD3(repeating: greySignal))
        XCTAssertEqual(grey.x, 0.18, accuracy: 2e-5)
        XCTAssertNotEqual(grey.x, powf(0.18, HLGTransfer.systemGamma),
                          accuracy: 1e-3)
        XCTAssertEqual(source.sceneHeadroom, HLGSceneTransfer.headroom)
    }

    func testPQUses203NitReferenceWhite() {
        let source = VideoSourceColor(transfer: .pq, primaries: .rec2020)
        let reference = source.linearRec2020(SIMD3(
            repeating: pqSignal(nits: 203)))
        XCTAssertEqual(reference.x, 1, accuracy: 2e-4)
        let peak = source.linearRec2020(SIMD3(repeating: 1))
        XCTAssertEqual(peak.x, 10_000 / 203, accuracy: 2e-3)
        XCTAssertEqual(source.sceneHeadroom, PQSceneTransfer.headroom)
    }

    func testHDRSourcePrimariesAreConvertedAfterTransfer() {
        let source = VideoSourceColor(transfer: .hlg, primaries: .displayP3)
        let code = HLGSceneTransfer.diffuseWhiteSignal
        let converted = source.linearRec2020(SIMD3(code, 0, 0))
        let expected = ColorScience.linearDisplayP3ToRec2020(SIMD3(1, 0, 0))
        XCTAssertEqual(converted.x, expected.x, accuracy: 2e-5)
        XCTAssertEqual(converted.y, expected.y, accuracy: 2e-5)
        XCTAssertEqual(converted.z, expected.z, accuracy: 2e-5)
    }
}

#if canImport(CoreMedia)
import CoreMedia
import CoreVideo

extension VideoSourceColorTests {
    private func format(
        transfer: CFString?, primaries: CFString? = nil,
        bits: Int? = nil
    ) throws -> CMFormatDescription {
        var extensions: [CFString: Any] = [:]
        if let transfer {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
        }
        if let primaries {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
        }
        if let bits {
            extensions[kCMFormatDescriptionExtension_BitsPerComponent] = bits
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 1920, height: 1080,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description)
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(description)
    }

    func testTagsRecognizeHLGAndPQIndependentOfBitDepth() throws {
        let eightBitHLG = try format(
            transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            bits: 8)
        let hlg = VideoSourceColor.tagged(in: [eightBitHLG])
        XCTAssertEqual(hlg.transfer, .hlg)
        XCTAssertEqual(hlg.primaries, .rec2020)
        XCTAssertTrue(hlg.isHDR)
        XCTAssertTrue(VideoDecodeDepth.road(
            hdr: false, log: false, sourceHDR: hlg.isHDR,
            sourceFormats: [eightBitHLG]).deepInput)

        let pq = VideoSourceColor.tagged(in: [try format(
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_P3_D65,
            bits: 10)])
        XCTAssertEqual(pq.transfer, .pq)
        XCTAssertEqual(pq.primaries, .displayP3)
    }

    func testTenBitSDRIsNotClassifiedAsHDR() throws {
        let tenBitSDR = try format(
            transfer: kCVImageBufferTransferFunction_sRGB,
            primaries: kCVImageBufferColorPrimaries_P3_D65,
            bits: 10)
        let source = VideoSourceColor.tagged(in: [tenBitSDR])
        XCTAssertFalse(source.isHDR)
        XCTAssertEqual(source, .colorManagedSDR)
        XCTAssertTrue(VideoDecodeDepth.isDeep([tenBitSDR]),
                      "precision remains independent of dynamic range")
    }
}
#endif
