#if canImport(AVFoundation)
import AVFoundation
import Accelerate
import CoreVideo
import Foundation
import VideoToolbox
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Writes movies with AVAssetWriter.
struct AVFoundationVideoWriters: HostVideoWriterFactory {
    var formats: [HostVideoFormat] { AVFoundationVideoWriter.formats }

    func writer(for format: HostVideoFormat) throws -> HostVideoWriter { AVFoundationVideoWriter() }
}

/// Encodes developed frames with AVAssetWriter in the formats the Mac app offers
/// (`VideoExportFormat`): H.264 in a QuickTime or MPEG-4 movie, 10-bit HEVC, and Apple ProRes.
/// The sound is carried across untouched where the container takes it.
final class AVFoundationVideoWriter: HostVideoWriter {
    static var formats: [HostVideoFormat] {
        HostVideoFormat.deliveries.filter { format in
            guard format.id == "prores4444xq" else { return true }
            if #available(macOS 15.0, iOS 18.0, *) { return true }
            return false
        }
    }

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var delivery: HostVideoDelivery?
    private var codec = AVVideoCodecType.h264
    private var audio: (reader: AVAssetReader, done: DispatchGroup)?
    private let audioQueue = DispatchQueue(label: "fotufilm.video.audio")

    private static func codec(_ id: String) -> AVVideoCodecType {
        switch id {
        case "hevc10": return .hevc
        case "prores422proxy": return .proRes422Proxy
        case "prores422lt": return .proRes422LT
        case "prores422": return .proRes422
        case "prores422hq": return .proRes422HQ
        case "prores4444": return .proRes4444
        case "prores4444xq":
            if #available(macOS 15.0, iOS 18.0, *) { return .appleProRes4444XQ }
            return AVVideoCodecType(rawValue: "ap4x")
        default: return .h264
        }
    }

    func begin(_ delivery: HostVideoDelivery) throws {
        self.delivery = delivery
        codec = Self.codec(delivery.format.id)
        let isProRes = delivery.format.id.hasPrefix("prores")
        let fileType: AVFileType = delivery.format.fileExtension == "mp4" ? .mp4 : .mov
        try? FileManager.default.removeItem(at: delivery.url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: delivery.url, fileType: fileType) }
        catch { throw HostEngine.Failure(description: "The video could not be written: \(error.localizedDescription)") }

        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: delivery.width,
                                       AVVideoHeightKey: delivery.height]
        let hdr = delivery.hdr && delivery.format.carriesHDR
        if hdr {
            // The Mac app's HDR colorimetry: BT.2020 primaries, HLG, BT.2020 matrix.
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        if !isProRes {
            // The Mac app's SDR colorimetry: Display P3 primaries, the sRGB transfer, BT.709 matrix.
            if !hdr {
                settings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                    AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ]
            }
            let rate = Int(delivery.frameRate.rounded())
            var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: rate,
                                              AVVideoMaxKeyFrameIntervalKey: rate * 2]
            // Automatic leaves VideoToolbox to derive its own rate, as the Mac app does.
            if let bitsPerPixel = delivery.bitrate.bitsPerPixel(hdr: hdr) {
                compression[AVVideoAverageBitRateKey] =
                    Int(Double(delivery.width * delivery.height) * delivery.frameRate * bitsPerPixel)
            }
            if codec == .hevc {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw HostEngine.Failure(description: "\(delivery.format.label) is unavailable on this Mac.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let pixelFormat = codec == .hevc ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : isProRes ? kCVPixelFormatType_64ARGB : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: delivery.width,
            kCVPixelBufferHeightKey as String: delivery.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else {
            throw HostEngine.Failure(description: "The video track could not be written.")
        }
        writer.add(input)
        let sound = (delivery.audio as? AVFoundationVideoSource).flatMap {
            addAudio(from: $0, to: writer, fileType: fileType, range: delivery.range)
        }
        guard writer.startWriting() else {
            throw HostEngine.Failure(description: "The video could not be written: "
                                     + (writer.error?.localizedDescription ?? "unknown error"))
        }
        // The movie starts at the trim's first frame: samples before it are edited out.
        writer.startSession(atSourceTime: CMTime(seconds: delivery.range.lowerBound,
                                                 preferredTimescale: 600_000))
        if let sound { startAudio(sound.reader, sound.output, into: sound.input) }
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    /// The source's sound over the range: passed through, or as AAC where the container takes
    /// no linear PCM (MPEG-4).
    private func addAudio(
        from source: AVFoundationVideoSource, to writer: AVAssetWriter, fileType: AVFileType,
        range: ClosedRange<Double>
    ) -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)? {
        guard let track = source.audioTrack, let reader = try? AVAssetReader(asset: source.asset),
              let hint = (try? waitFor { try await track.load(.formatDescriptions) })?.first
        else { return nil }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600_000),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600_000))
        let pcm = CMFormatDescriptionGetMediaSubType(hint) == kAudioFormatLinearPCM
        let output: AVAssetReaderTrackOutput, input: AVAssetWriterInput
        if pcm && fileType == .mp4 {
            let channels = CMAudioFormatDescriptionGetStreamBasicDescription(hint)?.pointee
                .mChannelsPerFrame ?? 2
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: min(2, Int(channels)),
            ])
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: min(2, Int(channels)), AVEncoderBitRateKey: 256_000,
            ])
        } else {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        }
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(output), writer.canAdd(input) else { return nil }
        reader.add(output)
        writer.add(input)
        return (reader, output, input)
    }

    /// Feeds the sound as the writer asks for it, beside the frames, so neither input starves
    /// the other.
    private func startAudio(_ reader: AVAssetReader, _ output: AVAssetReaderTrackOutput,
                            into input: AVAssetWriterInput) {
        let done = DispatchGroup()
        done.enter()
        guard reader.startReading() else {
            input.markAsFinished()
            done.leave()
            audio = (reader, done)
            return
        }
        input.requestMediaDataWhenReady(on: audioQueue) {
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                    input.markAsFinished()
                    done.leave()
                    return
                }
            }
        }
        audio = (reader, done)
    }

    func append(_ pixels: UnsafeRawBufferPointer, at seconds: Double) throws {
        guard let writer, let input, let adaptor, let delivery else { return }
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { break }
            usleep(500)
        }
        guard writer.status == .writing, let pool = adaptor.pixelBufferPool else {
            throw HostEngine.Failure(description: "The video could not be written: "
                                     + (writer.error?.localizedDescription ?? "the writer stopped"))
        }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess,
              let buffer = created else {
            throw HostEngine.Failure(description: "The video ran out of frame buffers.")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA:
            Self.fillBGRA(buffer, from: pixels, width: delivery.width, height: delivery.height)
        case kCVPixelFormatType_64ARGB:
            Self.fillProRes(buffer, from: pixels, width: delivery.width, height: delivery.height,
                            knee: delivery.shoulderKnee, hdr: delivery.hdr)
        default:
            Self.fill420(buffer, from: pixels, width: delivery.width, height: delivery.height,
                         knee: delivery.shoulderKnee, hdr: delivery.hdr)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds,
                                                                  preferredTimescale: 600_000)) else {
            throw HostEngine.Failure(description: "The video could not be written: "
                                     + (writer.error?.localizedDescription ?? "a frame was refused"))
        }
    }

    func finish() throws {
        guard let writer, let input, let delivery else { return }
        input.markAsFinished()
        audio?.done.wait()
        writer.endSession(atSourceTime: CMTime(seconds: delivery.range.upperBound,
                                               preferredTimescale: 600_000))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw HostEngine.Failure(description: "The video could not be finished: "
                                     + (writer.error?.localizedDescription ?? "unknown error"))
        }
    }

    func cancel() {
        audio?.reader.cancelReading()
        if writer?.status == .writing { writer?.cancelWriting() }
        if let url = delivery?.url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Frames

    /// Dithered Display P3 bytes, RGBA to the encoder's BGRA.
    private static func fillBGRA(_ buffer: CVPixelBuffer, from pixels: UnsafeRawBufferPointer,
                                 width: Int, height: Int) {
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels.baseAddress!),
                                   height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: width * 4)
        var destination = vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer),
                                        height: vImagePixelCount(height),
                                        width: vImagePixelCount(width),
                                        rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        vImagePermuteChannels_ARGB8888(&source, &destination, [2, 1, 0, 3],
                                       vImage_Flags(kvImageNoFlags))
    }

    /// Linear light as 16-bit big-endian ARGB: Apple's recommended ProRes input, as the Mac
    /// app's `ProResRecording` writes it.
    private static func fillProRes(_ buffer: CVPixelBuffer, from pixels: UnsafeRawBufferPointer,
                                   width: Int, height: Int, knee: Float, hdr: Bool) {
        HostVideoPixels.fillRGB16(pixels, width: width, height: height, knee: knee, hdr: hdr,
                                  into: CVPixelBufferGetBaseAddress(buffer)!,
                                  rowBytes: CVPixelBufferGetBytesPerRow(buffer),
                                  layout: .argbBigEndian)
        hdr ? attachHDRColor(buffer) : attachSDRColor(buffer)
    }

    /// The same light as 10-bit 4:2:0 video-range Y′CbCr, as `SDR10Recording` and
    /// `HLGRecording` write it.
    private static func fill420(_ buffer: CVPixelBuffer, from pixels: UnsafeRawBufferPointer,
                                width: Int, height: Int, knee: Float, hdr: Bool) {
        HostVideoPixels.fillP010(
            pixels, width: width, height: height, knee: knee, hdr: hdr,
            luma: CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self),
            lumaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2,
            chroma: CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self),
            chromaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2)
        if hdr { return attachHDRColor(buffer) }
        attachSDRColor(buffer)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Center, .shouldPropagate)
    }

    private static func attachHDRColor(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }

    private static func attachSDRColor(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
#endif
