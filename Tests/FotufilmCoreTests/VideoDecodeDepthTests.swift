import XCTest
@testable import FotufilmImaging
#if canImport(CoreMedia)
import CoreMedia

final class VideoDecodeDepthTests: XCTestCase {

    private func format(
        codec: CMVideoCodecType, extensions: [CFString: Any] = [:]
    ) throws -> CMFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: 3840, height: 2160,
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &description)
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(description)
    }

    private func hvcC(bits: Int, byteCount: Int = 23) -> Data {
        var record = Data(repeating: 0, count: byteCount)
        record[0] = 1
        if byteCount > 17 {
            record[17] = UInt8(0xF8 | (bits - 8))
        }
        if byteCount > 18 {
            record[18] = UInt8(0xF8 | (bits - 8))
        }
        return record
    }

    private func hevc(
        bits: Int, byteCount: Int = 23
    ) throws -> CMFormatDescription {
        try format(
            codec: kCMVideoCodecType_HEVC,
            extensions: [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:
                    ["hvcC": hvcC(bits: bits, byteCount: byteCount)],
            ])
    }

    func testTenBitSourceIsDeepWithoutAnHDRDelivery() throws {
        let source = try hevc(bits: 10)
        XCTAssertTrue(
            VideoDecodeDepth.road(hdr: false, log: false, sourceFormats: [source])
                .deepInput,
            "a 10-bit source takes the float road on every platform, and an "
            + "SDR delivery is not permission to decode it at 8 bits")
    }

    func testEightBitSourceIsNotDeepWithoutAnHDRDelivery() throws {
        let source = try hevc(bits: 8)
        XCTAssertFalse(
            VideoDecodeDepth.road(hdr: false, log: false, sourceFormats: [source])
                .deepInput)
    }

    func testHDRDeliveryIsDeepEvenFromAnEightBitSource() throws {
        let source = try hevc(bits: 8)
        XCTAssertTrue(
            VideoDecodeDepth.road(hdr: true, log: false, sourceFormats: [source])
                .deepInput)
    }

    func testNoFormatsFallsBackToTheDeliveryAlone() {
        XCTAssertFalse(
            VideoDecodeDepth.road(hdr: false, log: false, sourceFormats: []).deepInput)
        XCTAssertTrue(
            VideoDecodeDepth.road(hdr: true, log: false, sourceFormats: []).deepInput)
    }

    func testLogSourceIsDeepWhateverTheContainerSays() throws {
        for source in [try hevc(bits: 8), try format(codec: kCMVideoCodecType_H264)] {
            XCTAssertTrue(
                VideoDecodeDepth.road(hdr: false, log: true,
                                      sourceFormats: [source]).deepInput,
                "a log clip is a deep source by definition; the container's "
                + "8-bit answer is not permission to decode it at 8 bits")
        }
        XCTAssertTrue(
            VideoDecodeDepth.road(hdr: false, log: true, sourceFormats: [])
                .deepInput,
            "a clip whose formats would not load is exactly the case the log "
            + "flag has to carry on its own")
    }

    func testLogSourceRunsTheReferenceSchedule() throws {
        let source = try hevc(bits: 8)
        XCTAssertFalse(
            VideoDecodeDepth.road(hdr: false, log: true,
                                  sourceFormats: [source]).realtimeSchedule)
        XCTAssertFalse(
            VideoDecodeDepth.road(hdr: true, log: true,
                                  sourceFormats: [source]).realtimeSchedule)
    }

    func testTheLogFlagIsWhatMakesTheDifference() throws {
        let source = try hevc(bits: 8)
        XCTAssertNotEqual(
            VideoDecodeDepth.road(hdr: false, log: true, sourceFormats: [source]),
            VideoDecodeDepth.road(hdr: false, log: false, sourceFormats: [source]))
    }

    func testBothDeliveriesOfAClipAgreeOnTheSchedule() throws {
        for bits in [8, 10, 12] {
            for log in [false, true] {
                let source = try hevc(bits: bits)
                let sdr = VideoDecodeDepth.road(hdr: false, log: log,
                                                sourceFormats: [source])
                let hdr = VideoDecodeDepth.road(hdr: true, log: log,
                                                sourceFormats: [source])
                XCTAssertEqual(
                    sdr.realtimeSchedule, hdr.realtimeSchedule,
                    "the SDR and HDR deliveries of one \(bits)-bit clip are "
                    + "the same develop, so they cannot run different "
                    + "schedules")
            }
        }
    }

    func testDeepSourceRunsTheReferenceSchedule() throws {
        let source = try hevc(bits: 10)
        XCTAssertFalse(
            VideoDecodeDepth.road(hdr: false, log: false, sourceFormats: [source])
                .realtimeSchedule)
        XCTAssertFalse(
            VideoDecodeDepth.road(hdr: true, log: false, sourceFormats: [source])
                .realtimeSchedule,
            "an HDR delivery of a deep source used to be forced onto the "
            + "realtime schedule, which made it a different print from the "
            + "SDR delivery of the same clip")
    }

    func testEightBitSourceRunsTheRealtimeSchedule() throws {
        let source = try hevc(bits: 8)
        XCTAssertTrue(
            VideoDecodeDepth.road(hdr: false, log: false, sourceFormats: [source])
                .realtimeSchedule)
        XCTAssertTrue(
            VideoDecodeDepth.road(hdr: true, log: false, sourceFormats: [source])
                .realtimeSchedule)
    }

    func testUnreadableSourceRunsTheRealtimeSchedule() {
        XCTAssertTrue(
            VideoDecodeDepth.road(hdr: false, log: false, sourceFormats: [])
                .realtimeSchedule)
        XCTAssertTrue(
            VideoDecodeDepth.road(hdr: true, log: false, sourceFormats: [])
                .realtimeSchedule)
    }

    func testOneDeepDescriptionMakesTheTrackDeep() throws {
        let shallow = try hevc(bits: 8)
        let deep = try hevc(bits: 10)
        XCTAssertTrue(VideoDecodeDepth.isDeep([shallow, deep]))
        XCTAssertTrue(VideoDecodeDepth.isDeep([deep, shallow]))
        XCTAssertFalse(VideoDecodeDepth.isDeep([shallow, shallow]))
    }

    func testNamedBitsPerComponentIsAuthoritative() throws {
        let named = try format(
            codec: kCMVideoCodecType_AppleProRes422,
            extensions: [kCMFormatDescriptionExtension_BitsPerComponent: 12])
        XCTAssertEqual(VideoDecodeDepth.bitsPerComponent(named), 12)
    }

    func testProResFlavoursCarryTheirKnownDepths() throws {
        for codec in [kCMVideoCodecType_AppleProRes422Proxy,
                      kCMVideoCodecType_AppleProRes422LT,
                      kCMVideoCodecType_AppleProRes422,
                      kCMVideoCodecType_AppleProRes422HQ] {
            XCTAssertEqual(
                VideoDecodeDepth.bitsPerComponent(try format(codec: codec)),
                10)
        }
        for codec in [kCMVideoCodecType_AppleProRes4444,
                      kCMVideoCodecType_AppleProRes4444XQ] {
            XCTAssertEqual(
                VideoDecodeDepth.bitsPerComponent(try format(codec: codec)),
                12)
        }
    }

    func testHEVCDepthComesFromTheConfigurationRecord() throws {
        XCTAssertEqual(VideoDecodeDepth.bitsPerComponent(try hevc(bits: 8)), 8)
        XCTAssertEqual(
            VideoDecodeDepth.bitsPerComponent(try hevc(bits: 10)), 10)
        XCTAssertEqual(
            VideoDecodeDepth.bitsPerComponent(try hevc(bits: 12)), 12)
    }

    func testHEVCDepthIsReadUnderEveryHEVCSubtype() throws {
        let atoms: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:
                ["hvcC": hvcC(bits: 10)],
        ]
        let hev1 = CMVideoCodecType(0x68657631)
        XCTAssertEqual(
            VideoDecodeDepth.bitsPerComponent(
                try format(codec: hev1, extensions: atoms)), 10)
        XCTAssertEqual(
            VideoDecodeDepth.bitsPerComponent(
                try format(codec: kCMVideoCodecType_DolbyVisionHEVC,
                           extensions: atoms)), 10)
    }

    // MARK: The container the path decodes into

    func testDeepRoadDecodesIntoTheDeepContainer() throws {
        let source = try hevc(bits: 10)
        XCTAssertEqual(
            VideoDecodeDepth.road(hdr: false, log: false, sourceFormats: [source])
                .pixelFormat,
            kCVPixelFormatType_128RGBAFloat)
    }

    func testShallowRoadDecodesIntoBGRA() throws {
        let source = try hevc(bits: 8)
        XCTAssertEqual(
            VideoDecodeDepth.road(hdr: false, log: false, sourceFormats: [source])
                .pixelFormat,
            kCVPixelFormatType_32BGRA)
    }

    func testHDRDeliveryDecodesIntoTheDeepContainer() throws {
        let source = try hevc(bits: 8)
        XCTAssertEqual(
            VideoDecodeDepth.road(hdr: true, log: false, sourceFormats: [source])
                .pixelFormat,
            kCVPixelFormatType_128RGBAFloat)
    }

    func testTheContainerFollowsTheRoadAndNothingElse() throws {
        for bits in [8, 10, 12] {
            for hdr in [false, true] {
                for log in [false, true] {
                    let road = VideoDecodeDepth.road(
                        hdr: hdr, log: log,
                        sourceFormats: [try hevc(bits: bits)])
                    XCTAssertEqual(
                        road.pixelFormat,
                        road.deepInput ? kCVPixelFormatType_128RGBAFloat
                                       : kCVPixelFormatType_32BGRA,
                        "\(bits)-bit source, hdr: \(hdr), log: \(log)")
                }
            }
        }
    }

    func testFloatContainerKeepsEveryTwelveBitCodeApart() {
        var throughBGRA = Set<UInt8>()
        var throughFloat = Set<UInt32>()
        var throughHalf = Set<UInt16>()
        for code in 0..<4096 {
            let value = Float(code) / 4095
            throughBGRA.insert(UInt8((value * 255).rounded()))
            throughFloat.insert(value.bitPattern)
            throughHalf.insert(Float16(value).bitPattern)
        }
        XCTAssertEqual(throughFloat.count, 4096)
        XCTAssertLessThan(throughHalf.count, 4096,
                          "half float silently collapsed decoded 12-bit codes")
        XCTAssertEqual(throughBGRA.count, 256,
                       "8-bit BGRA keeps one sixteenth of them; the preview was "
                       + "grading against three quarters of the signal thrown "
                       + "away, while the export developed all of it")
    }

    func testUnreadableSourcesReadAsShallow() throws {
        XCTAssertEqual(
            VideoDecodeDepth.bitsPerComponent(
                try format(codec: kCMVideoCodecType_H264)), 8)
        XCTAssertEqual(
            VideoDecodeDepth.bitsPerComponent(
                try format(codec: kCMVideoCodecType_HEVC)), 8)
        XCTAssertEqual(
            VideoDecodeDepth.bitsPerComponent(
                try hevc(bits: 10, byteCount: 17)), 8)
    }
}
#endif
