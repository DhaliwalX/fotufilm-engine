#if canImport(AVFoundation) && canImport(Metal) && canImport(VideoToolbox)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox
import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging
@testable import FotufilmMetal

/// End-to-end proof for the camera recording boundary. Unlike the delivery parity tests, this
/// crosses the CVPixelBuffer, VideoToolbox, QuickTime, and AVFoundation decode boundaries too.
/// Keep the generated movie by setting `FOTUFILM_KEEP_HDR_RECORDING_PROOF=1`.
final class HDRRecordingRoundTripTests: XCTestCase {
    private static let width = 640
    private static let height = 320
    private static let frameRate = 30
    private static let frameCount = 12
    private static let columns = 4

    private struct Patch {
        let name: String
        let rgb: SIMD3<Float>
    }

    private static let patches = [
        Patch(name: "black", rgb: SIMD3(repeating: 0)),
        Patch(name: "18%-grey", rgb: SIMD3(repeating: 0.18)),
        Patch(name: "diffuse-white", rgb: SIMD3(repeating: 1)),
        Patch(name: "highlight", rgb: SIMD3(repeating: 3)),
        Patch(name: "p3-red", rgb: SIMD3(1, 0, 0)),
        Patch(name: "p3-green", rgb: SIMD3(0, 1, 0)),
        Patch(name: "p3-blue", rgb: SIMD3(0, 0, 1)),
        Patch(name: "orange", rgb: SIMD3(1, 0.15, 0.02)),
    ]

    private struct PlaneCodes {
        let width: Int
        let height: Int
        let luma: [UInt16]
        let cb: [UInt16]
        let cr: [UInt16]
        let nonzeroPaddingWords: Int
    }

    private struct BufferTags {
        let format: String
        let primaries: String
        let transfer: String
        let matrix: String
    }

    private struct RGBDecode {
        let patches: [SIMD3<Float>]
        let tags: BufferTags
    }

    private struct YCbCrDecode {
        let planes: PlaneCodes
        let tags: BufferTags
    }

    private struct ErrorStats {
        let mean: Float
        let maximum: Float
    }

    private struct TrackProof {
        let codec: String
        let bits: Int
        let primaries: String
        let transfer: String
        let matrix: String
    }

    private enum ProofError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(reason): return reason
            }
        }
    }

    func testCameraMain10HLGRoundTripLocatesColourShift() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-hdr-recording-proof-\(UUID().uuidString).mov")
        defer {
            if ProcessInfo.processInfo.environment["FOTUFILM_KEEP_HDR_RECORDING_PROOF"] == "1" {
                print("HDR_RECORDING_PROOF file=\(outputURL.path)")
            } else {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let source = try await writeCameraEquivalentMovie(to: outputURL, device: device)
        let track = try await inspectTrack(at: outputURL)
        let rawDecode = try await decodeYCbCr(at: outputURL)
        let raw = rawDecode.planes
        let untouched = try await decodeRawRGB(at: outputURL)

        let correct = try await decodeRGB(
            at: outputURL, transfer: AVVideoTransferFunction_Linear,
            matrix: AVVideoYCbCrMatrix_ITU_R_2020, allowWideColor: true,
            linearizeSRGB: false)
        let wrongMatrixOnly = try await decodeRGB(
            at: outputURL, transfer: AVVideoTransferFunction_Linear,
            matrix: AVVideoYCbCrMatrix_ITU_R_709_2, allowWideColor: true,
            linearizeSRGB: false)
        let encodedTransferOnly = try await decodeRGB(
            at: outputURL, transfer: sRGBTransferFunction,
            matrix: AVVideoYCbCrMatrix_ITU_R_2020, allowWideColor: true,
            linearizeSRGB: true)
        // Retained as a regression witness for the former SDR request applied to HLG input.
        let legacySDRDecode = try await decodeRGB(
            at: outputURL, transfer: sRGBTransferFunction,
            matrix: AVVideoYCbCrMatrix_ITU_R_709_2, allowWideColor: false,
            linearizeSRGB: true)

        let lumaError = planeError(source.luma, raw.luma, plane: .luma)
        let cbError = planeError(source.cb, raw.cb, plane: .chroma)
        let crError = planeError(source.cr, raw.cr, plane: .chroma)
        let normalChromaError = combinedChromaError(
            expectedCB: source.cb, expectedCR: source.cr,
            actualCB: raw.cb, actualCR: raw.cr, swapped: false)
        let swappedChromaError = combinedChromaError(
            expectedCB: source.cb, expectedCR: source.cr,
            actualCB: raw.cb, actualCR: raw.cr, swapped: true)

        let expectedRGB = Self.patches.map {
            HLGTransfer.hdrShoulderPreservingHue($0.rgb)
        }
        let expectedSceneRGB = expectedRGB.map { display -> SIMD3<Float> in
            let wide = ColorScience.linearDisplayP3ToRec2020(display)
            let open = HLGTransfer.opticalToOpen(
                r: wide.x, g: wide.y, b: wide.z)
            return SIMD3(open.r, open.g, open.b)
        }
        let hlgSource = VideoSourceColor(transfer: .hlg, primaries: .rec2020)
        let decodedSceneRGB = untouched.patches.map(hlgSource.linearRec2020)
        // AVFoundation's linear HLG output is the inverse-OETF scene signal with the HLG
        // reference scale (the OETF's 12 multiplier), not display light. Undo that scale and
        // restore the display OOTF before comparing it with the display-linear master.
        let correctDisplayRGB = correct.patches.map {
            Self.displayMaster(fromAppleLinearHLG: $0)
        }
        let wrongMatrixDisplayRGB = wrongMatrixOnly.patches.map {
            Self.displayMaster(fromAppleLinearHLG: $0)
        }
        let rawRGB = reconstructRGB(from: raw)
        let rawRGBError = rgbError(rawRGB, expectedRGB)
        let correctError = rgbError(correctDisplayRGB, expectedRGB)
        let wrongMatrixError = rgbError(wrongMatrixDisplayRGB, expectedRGB)
        let encodedTransferError = rgbError(encodedTransferOnly.patches, expectedRGB)
        let sceneError = rgbError(decodedSceneRGB, expectedSceneRGB)
        let legacySDRError = rgbError(legacySDRDecode.patches, expectedRGB)

        print(
            "HDR_RECORDING_PROOF track codec=\(track.codec) bits=\(track.bits) "
                + "primaries=\(track.primaries) transfer=\(track.transfer) "
                + "matrix=\(track.matrix)")
        print(
            "HDR_RECORDING_PROOF raw format=\(rawDecode.tags.format) "
                + "primaries=\(rawDecode.tags.primaries) "
                + "transfer=\(rawDecode.tags.transfer) "
                + "matrix=\(rawDecode.tags.matrix)")
        print(
            "HDR_RECORDING_PROOF x420 luma_mae=\(decimal(lumaError.mean)) "
                + "luma_max=\(decimal(lumaError.maximum)) "
                + "cb_mae=\(decimal(cbError.mean)) cb_max=\(decimal(cbError.maximum)) "
                + "cr_mae=\(decimal(crError.mean)) cr_max=\(decimal(crError.maximum)) "
                + "normal_chroma_mae=\(decimal(normalChromaError.mean)) "
                + "swapped_chroma_mae=\(decimal(swappedChromaError.mean)) "
                + "source_padding_words=\(source.nonzeroPaddingWords) "
                + "decoded_padding_words=\(raw.nonzeroPaddingWords)")
        printRGBProof("raw-manual", tags: nil, error: rawRGBError)
        printRGBProof("apple-linear-2020", tags: correct.tags, error: correctError)
        printRGBProof("linear-709", tags: wrongMatrixOnly.tags, error: wrongMatrixError)
        printRGBProof("srgb-2020", tags: encodedTransferOnly.tags, error: encodedTransferError)
        printRGBProof("scene-linear-2020", tags: untouched.tags, error: sceneError)
        printRGBProof("legacy-srgb-709", tags: legacySDRDecode.tags, error: legacySDRError)
        for index in Self.patches.indices {
            let expected = expectedRGB[index]
            print(
                "HDR_RECORDING_PROOF patch=\(Self.patches[index].name) "
                    + "display=\(vector(expected)) "
                    + "apple_display=\(vector(correctDisplayRGB[index])) "
                    + "expected_scene=\(vector(expectedSceneRGB[index])) "
                    + "decoded_scene=\(vector(decodedSceneRGB[index]))")
        }

        XCTAssertEqual(track.codec, "hvc1")
        XCTAssertEqual(track.bits, 10)
        XCTAssertEqual(track.primaries, kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual(track.transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        XCTAssertEqual(track.matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        XCTAssertEqual(source.nonzeroPaddingWords, 0, "x420 codes must occupy the 10 MSBs")
        XCTAssertLessThan(normalChromaError.mean, swappedChromaError.mean * 0.35,
                          "the file no longer carries Cb then Cr")
        XCTAssertLessThan(rawRGBError.mean, 0.035,
                          "HEVC/x420 no longer reconstructs the delivered linear P3 image")
        XCTAssertLessThan(correctError.mean, 0.04,
                          "Apple's documented HDR decode no longer reconstructs the source")
        XCTAssertLessThan(sceneError.mean, 0.04,
                          "raw HLG no longer reconstructs scene-linear Rec.2020")
        XCTAssertLessThan(correctError.mean, legacySDRError.mean,
                          "the legacy SDR request no longer demonstrates its colour error")
    }

    /// The platform-linear HLG decode is useful for checking a delivered display master, but it is
    /// not the app's film-input conversion. Production ingest now decodes raw HLG directly to
    /// scene-linear Rec.2020 without this OOTF.
    private static func displayMaster(fromAppleLinearHLG value: SIMD3<Float>)
        -> SIMD3<Float> {
        let to2020 = HLGTransfer.displayP3ToRec2020
        let decoded2020 = SIMD3<Float>(
            to2020[0] * value.x + to2020[1] * value.y + to2020[2] * value.z,
            to2020[3] * value.x + to2020[4] * value.y + to2020[5] * value.z,
            to2020[6] * value.x + to2020[7] * value.y + to2020[8] * value.z)
        let open = decoded2020 * (PrintEncoding.hdrHeadroom / 12)
        let optical = HLGTransfer.openToOptical(
            r: open.x, g: open.y, b: open.z)
        let toP3 = HLGTransfer.rec2020ToDisplayP3
        return SIMD3<Float>(
            toP3[0] * optical.r + toP3[1] * optical.g + toP3[2] * optical.b,
            toP3[3] * optical.r + toP3[4] * optical.g + toP3[5] * optical.b,
            toP3[6] * optical.r + toP3[7] * optical.g + toP3[8] * optical.b)
    }

    // MARK: - Encode

    private func writeCameraEquivalentMovie(
        to url: URL, device: MTLDevice
    ) async throws -> PlaneCodes {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey:
                Int(Double(Self.width * Self.height * Self.frameRate) * 0.18),
            AVVideoExpectedSourceFrameRateKey: Self.frameRate,
            AVVideoMaxKeyFrameIntervalKey: Self.frameRate * 2,
            kVTCompressionPropertyKey_HDRMetadataInsertionMode as String:
                kVTHDRMetadataInsertionMode_Auto,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
        ]
        let colour: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Self.width,
                AVVideoHeightKey: Self.height,
                AVVideoColorPropertiesKey: colour,
                AVVideoCompressionPropertiesKey: compression,
            ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ])
        guard writer.canAdd(input) else {
            throw ProofError.failed("AVAssetWriter rejected the CameraRecorder Main10 input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ProofError.failed(
                "AVAssetWriter could not start: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        let master = try makeMasterTexture(device: device)
        let delivery = try HandwrittenMetalDigitalDelivery(device: device)
        guard let queue = device.makeCommandQueue() else {
            throw ProofError.failed("could not make Metal command queue")
        }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
                == kCVReturnSuccess, let textureCache,
              let pool = adaptor.pixelBufferPool
        else { throw ProofError.failed("could not make the writer's x420 Metal pool") }

        var firstCodes: PlaneCodes?
        for frame in 0..<Self.frameCount {
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing {
                    throw ProofError.failed(
                        "writer stopped before frame \(frame): "
                            + (writer.error?.localizedDescription ?? "unknown"))
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var optionalPixels: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalPixels)
                    == kCVReturnSuccess, let pixels = optionalPixels
            else { throw ProofError.failed("could not allocate x420 frame \(frame)") }
            attachCameraHDRColour(to: pixels)

            var lumaReference: CVMetalTexture?
            var chromaReference: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                    nil, textureCache, pixels, nil, .r16Unorm,
                    Self.width, Self.height, 0, &lumaReference) == kCVReturnSuccess,
                  CVMetalTextureCacheCreateTextureFromImage(
                    nil, textureCache, pixels, nil, .rg16Unorm,
                    Self.width / 2, Self.height / 2, 1,
                    &chromaReference) == kCVReturnSuccess,
                  let lumaReference, let chromaReference,
                  let luma = CVMetalTextureGetTexture(lumaReference),
                  let chroma = CVMetalTextureGetTexture(chromaReference),
                  let commands = queue.makeCommandBuffer()
            else { throw ProofError.failed("could not map x420 frame \(frame) into Metal") }
            try delivery.encode(
                master: master, luma: luma, chroma: chroma,
                output: .hdrHLGRec2020, commandBuffer: commands)
            commands.commit()
            await commands.completed()
            guard commands.status == .completed else {
                throw ProofError.failed(
                    "delivery command failed: \(commands.error?.localizedDescription ?? "unknown")")
            }
            if firstCodes == nil { firstCodes = try readPlanes(pixels) }
            guard adaptor.append(
                    pixels,
                    withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                 timescale: CMTimeScale(Self.frameRate)))
            else {
                throw ProofError.failed(
                    "writer rejected frame \(frame): "
                        + (writer.error?.localizedDescription ?? "unknown"))
            }
            withExtendedLifetime((pixels, lumaReference, chromaReference)) {}
        }

        input.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(value: CMTimeValue(Self.frameCount),
                                 timescale: CMTimeScale(Self.frameRate)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProofError.failed(
                "writer did not finish: \(writer.error?.localizedDescription ?? "unknown")")
        }
        guard let firstCodes else { throw ProofError.failed("writer produced no frames") }
        return firstCodes
    }

    private func makeMasterTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Self.width,
            height: Self.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ProofError.failed("could not allocate RGBA16F source")
        }
        let patchWidth = Self.width / Self.columns
        let patchHeight = Self.height / 2
        var storage = [Float16](repeating: 0, count: Self.width * Self.height * 4)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let patch = Self.patches[(y / patchHeight) * Self.columns + x / patchWidth]
                let offset = (y * Self.width + x) * 4
                storage[offset] = Float16(patch.rgb.x)
                storage[offset + 1] = Float16(patch.rgb.y)
                storage[offset + 2] = Float16(patch.rgb.z)
                storage[offset + 3] = 1
            }
        }
        storage.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, Self.width, Self.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: Self.width * 8)
        }
        return texture
    }

    private func attachCameraHDRColour(to pixels: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixels, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(
            pixels, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(
            pixels, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(
            pixels, kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Center, .shouldPropagate)
    }

    // MARK: - Decode and inspect

    private func inspectTrack(at url: URL) async throws -> TrackProof {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let description = try await track.load(.formatDescriptions).first
        else { throw ProofError.failed("encoded movie has no video format") }
        return TrackProof(
            codec: fourCC(CMFormatDescriptionGetMediaSubType(description)),
            bits: VideoDecodeDepth.bitsPerComponent(description),
            primaries: formatTag(description, kCMFormatDescriptionExtension_ColorPrimaries),
            transfer: formatTag(description, kCMFormatDescriptionExtension_TransferFunction),
            matrix: formatTag(description, kCMFormatDescriptionExtension_YCbCrMatrix))
    }

    private func decodeYCbCr(at url: URL) async throws -> YCbCrDecode {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProofError.failed("encoded movie has no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ProofError.failed("reader rejected native x420 output")
        }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let pixels = CMSampleBufferGetImageBuffer(sample)
        else {
            throw ProofError.failed(
                "reader produced no x420 frame: \(reader.error?.localizedDescription ?? "unknown")")
        }
        return YCbCrDecode(planes: try readPlanes(pixels), tags: bufferTags(pixels))
    }

    private func decodeRGB(
        at url: URL, transfer: String, matrix: String,
        allowWideColor: Bool, linearizeSRGB: Bool
    ) async throws -> RGBDecode {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProofError.failed("encoded movie has no video track")
        }
        let colour: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_128RGBAFloat,
            AVVideoColorPropertiesKey: colour,
        ]
        if allowWideColor { settings[AVVideoAllowWideColorKey] = true }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ProofError.failed(
                "reader rejected RGB output transfer=\(transfer) matrix=\(matrix)")
        }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let pixels = CMSampleBufferGetImageBuffer(sample)
        else {
            throw ProofError.failed(
                "reader produced no RGB frame: \(reader.error?.localizedDescription ?? "unknown")")
        }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_128RGBAFloat
        else {
            throw ProofError.failed(
                "reader returned \(fourCC(CVPixelBufferGetPixelFormatType(pixels))) instead of RGBAFloat")
        }
        return RGBDecode(
            patches: try readRGBPatches(pixels, linearizeSRGB: linearizeSRGB),
            tags: bufferTags(pixels))
    }

    /// The production standard-HDR decoder contract: RGBA float with no requested transfer,
    /// primaries, or gamut conversion. `VideoSourceColor` interprets the arriving HLG codes.
    private func decodeRawRGB(at url: URL) async throws -> RGBDecode {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProofError.failed("encoded movie has no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_128RGBAFloat,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ProofError.failed("reader rejected raw RGBA float output")
        }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let pixels = CMSampleBufferGetImageBuffer(sample)
        else {
            throw ProofError.failed(
                "reader produced no raw RGB frame: "
                    + (reader.error?.localizedDescription ?? "unknown"))
        }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_128RGBAFloat
        else {
            throw ProofError.failed(
                "reader returned \(fourCC(CVPixelBufferGetPixelFormatType(pixels))) "
                    + "instead of raw RGBAFloat")
        }
        return RGBDecode(
            patches: try readRGBPatches(pixels, linearizeSRGB: false),
            tags: bufferTags(pixels))
    }

    private func readPlanes(_ pixels: CVPixelBuffer) throws -> PlaneCodes {
        guard CVPixelBufferGetPixelFormatType(pixels)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixels) == 2
        else {
            throw ProofError.failed(
                "expected x420, got \(fourCC(CVPixelBufferGetPixelFormatType(pixels)))")
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)
        else { throw ProofError.failed("x420 planes are not CPU accessible") }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) / 2
        let cWidth = CVPixelBufferGetWidthOfPlane(pixels, 1)
        let cHeight = CVPixelBufferGetHeightOfPlane(pixels, 1)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) / 2
        let yWords = yBase.assumingMemoryBound(to: UInt16.self)
        let cWords = cBase.assumingMemoryBound(to: UInt16.self)
        var luma = [UInt16](repeating: 0, count: width * height)
        var cb = [UInt16](repeating: 0, count: cWidth * cHeight)
        var cr = [UInt16](repeating: 0, count: cWidth * cHeight)
        var nonzeroPadding = 0
        for y in 0..<height {
            for x in 0..<width {
                let word = yWords[y * yStride + x]
                nonzeroPadding += word & 63 == 0 ? 0 : 1
                luma[y * width + x] = word >> 6
            }
        }
        for y in 0..<cHeight {
            for x in 0..<cWidth {
                let cbWord = cWords[y * cStride + x * 2]
                let crWord = cWords[y * cStride + x * 2 + 1]
                nonzeroPadding += cbWord & 63 == 0 ? 0 : 1
                nonzeroPadding += crWord & 63 == 0 ? 0 : 1
                cb[y * cWidth + x] = cbWord >> 6
                cr[y * cWidth + x] = crWord >> 6
            }
        }
        return PlaneCodes(
            width: width, height: height, luma: luma, cb: cb, cr: cr,
            nonzeroPaddingWords: nonzeroPadding)
    }

    private func readRGBPatches(
        _ pixels: CVPixelBuffer, linearizeSRGB: Bool
    ) throws -> [SIMD3<Float>] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
            throw ProofError.failed("RGBAFloat frame is not CPU accessible")
        }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels) / 4
        let values = base.assumingMemoryBound(to: Float.self)
        return Self.patches.indices.map { patch in
            let bounds = interiorBounds(for: patch, width: width, height: height)
            var sum = SIMD3<Float>.zero
            var count: Float = 0
            for y in bounds.y {
                for x in bounds.x {
                    var rgb = SIMD3(
                        values[y * stride + x * 4],
                        values[y * stride + x * 4 + 1],
                        values[y * stride + x * 4 + 2])
                    if linearizeSRGB {
                        rgb = SIMD3(
                            decodeSRGB(rgb.x), decodeSRGB(rgb.y), decodeSRGB(rgb.z))
                    }
                    sum += rgb
                    count += 1
                }
            }
            return sum / count
        }
    }

    // MARK: - Measurements

    private enum PlaneKind { case luma, chroma }

    private func planeError(
        _ expected: [UInt16], _ actual: [UInt16], plane: PlaneKind
    ) -> ErrorStats {
        precondition(expected.count == actual.count)
        let width = plane == .luma ? Self.width : Self.width / 2
        let height = plane == .luma ? Self.height : Self.height / 2
        var errors: [Float] = []
        for patch in Self.patches.indices {
            let bounds = interiorBounds(for: patch, width: width, height: height)
            for y in bounds.y {
                for x in bounds.x {
                    errors.append(abs(Float(expected[y * width + x])
                                      - Float(actual[y * width + x])))
                }
            }
        }
        return stats(errors)
    }

    private func combinedChromaError(
        expectedCB: [UInt16], expectedCR: [UInt16],
        actualCB: [UInt16], actualCR: [UInt16], swapped: Bool
    ) -> ErrorStats {
        let width = Self.width / 2
        let height = Self.height / 2
        var errors: [Float] = []
        for patch in Self.patches.indices {
            let bounds = interiorBounds(for: patch, width: width, height: height)
            for y in bounds.y {
                for x in bounds.x {
                    let index = y * width + x
                    let cb = swapped ? actualCR[index] : actualCB[index]
                    let cr = swapped ? actualCB[index] : actualCR[index]
                    errors.append(abs(Float(expectedCB[index]) - Float(cb)))
                    errors.append(abs(Float(expectedCR[index]) - Float(cr)))
                }
            }
        }
        return stats(errors)
    }

    private func reconstructRGB(from planes: PlaneCodes) -> [SIMD3<Float>] {
        Self.patches.indices.map { patch in
            let yBounds = interiorBounds(
                for: patch, width: planes.width, height: planes.height)
            let cBounds = interiorBounds(
                for: patch, width: planes.width / 2, height: planes.height / 2)
            let y = meanCodes(planes.luma, width: planes.width, bounds: yBounds)
            let cb = meanCodes(planes.cb, width: planes.width / 2, bounds: cBounds)
            let cr = meanCodes(planes.cr, width: planes.width / 2, bounds: cBounds)
            let open = HLGTransfer.decode(luma: y, cb: cb, cr: cr)
            let optical = HLGTransfer.openToOptical(r: open.0, g: open.1, b: open.2)
            let m = HLGTransfer.rec2020ToDisplayP3
            return SIMD3(
                m[0] * optical.r + m[1] * optical.g + m[2] * optical.b,
                m[3] * optical.r + m[4] * optical.g + m[5] * optical.b,
                m[6] * optical.r + m[7] * optical.g + m[8] * optical.b)
        }
    }

    private func meanCodes(
        _ values: [UInt16], width: Int,
        bounds: (x: Range<Int>, y: Range<Int>)
    ) -> Float {
        var sum: UInt64 = 0
        var count: UInt64 = 0
        for y in bounds.y {
            for x in bounds.x {
                sum += UInt64(values[y * width + x])
                count += 1
            }
        }
        return Float(sum) / Float(count)
    }

    private func rgbError(
        _ actual: [SIMD3<Float>], _ expected: [SIMD3<Float>]
    ) -> ErrorStats {
        stats(zip(actual, expected).flatMap { value in
            [abs(value.0.x - value.1.x), abs(value.0.y - value.1.y),
             abs(value.0.z - value.1.z)]
        })
    }

    private func stats(_ errors: [Float]) -> ErrorStats {
        ErrorStats(
            mean: errors.reduce(0, +) / Float(max(errors.count, 1)),
            maximum: errors.max() ?? 0)
    }

    private func interiorBounds(
        for patch: Int, width: Int, height: Int
    ) -> (x: Range<Int>, y: Range<Int>) {
        let patchWidth = width / Self.columns
        let patchHeight = height / 2
        let originX = patch % Self.columns * patchWidth
        let originY = patch / Self.columns * patchHeight
        return (
            (originX + patchWidth / 4)..<(originX + patchWidth * 3 / 4),
            (originY + patchHeight / 4)..<(originY + patchHeight * 3 / 4))
    }

    private func decodeSRGB(_ value: Float) -> Float {
        let magnitude = abs(value)
        let linear = magnitude <= 0.04045
            ? magnitude / 12.92
            : powf((magnitude + 0.055) / 1.055, 2.4)
        return value < 0 ? -linear : linear
    }

    // MARK: - Tags and diagnostics

    private func bufferTags(_ pixels: CVPixelBuffer) -> BufferTags {
        BufferTags(
            format: fourCC(CVPixelBufferGetPixelFormatType(pixels)),
            primaries: bufferTag(pixels, kCVImageBufferColorPrimariesKey),
            transfer: bufferTag(pixels, kCVImageBufferTransferFunctionKey),
            matrix: bufferTag(pixels, kCVImageBufferYCbCrMatrixKey))
    }

    private func bufferTag(_ pixels: CVPixelBuffer, _ key: CFString) -> String {
        guard let value = CVBufferCopyAttachment(pixels, key, nil) else {
            return "missing"
        }
        return String(describing: value)
    }

    private func formatTag(
        _ description: CMFormatDescription, _ key: CFString
    ) -> String {
        guard let value = CMFormatDescriptionGetExtension(
                description, extensionKey: key)
        else { return "missing" }
        return String(describing: value)
    }

    private func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    private func printRGBProof(
        _ name: String, tags: BufferTags?, error: ErrorStats
    ) {
        let tagText = tags.map {
            " format=\($0.format) primaries=\($0.primaries) transfer=\($0.transfer) matrix=\($0.matrix)"
        } ?? ""
        print(
            "HDR_RECORDING_PROOF rgb path=\(name) mae=\(decimal(error.mean)) "
                + "max=\(decimal(error.maximum))\(tagText)")
    }

    private func decimal(_ value: Float) -> String {
        String(format: "%.6f", value)
    }

    private func vector(_ value: SIMD3<Float>) -> String {
        "[\(decimal(value.x)),\(decimal(value.y)),\(decimal(value.z))]"
    }

    #if os(macOS)
    private var sRGBTransferFunction: String {
        kCVImageBufferTransferFunction_sRGB as String
    }
    #else
    private var sRGBTransferFunction: String {
        AVVideoTransferFunction_IEC_sRGB
    }
    #endif
}
#endif
