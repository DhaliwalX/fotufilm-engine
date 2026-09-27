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
        var formats = [
            HostVideoFormat(id: "mp4", label: "MPEG-4 · H.264", fileExtension: "mp4",
                            mimeType: "video/mp4", takesLinearLight: false, compresses: true,
                            bits: 8),
            HostVideoFormat(id: "mov", label: "QuickTime · H.264", fileExtension: "mov",
                            mimeType: "video/quicktime", takesLinearLight: false, compresses: true,
                            bits: 8),
            HostVideoFormat(id: "hevc10", label: "HEVC 10-bit", fileExtension: "mp4",
                            mimeType: "video/mp4", takesLinearLight: true, compresses: true,
                            bits: 10),
        ]
        var proRes = [("prores422proxy", "Apple ProRes 422 Proxy"),
                      ("prores422lt", "Apple ProRes 422 LT"), ("prores422", "Apple ProRes 422"),
                      ("prores422hq", "Apple ProRes 422 HQ"), ("prores4444", "Apple ProRes 4444")]
        if #available(macOS 15.0, iOS 18.0, *) { proRes.append(("prores4444xq", "Apple ProRes 4444 XQ")) }
        formats += proRes.map {
            HostVideoFormat(id: $0.0, label: $0.1, fileExtension: "mov", mimeType: "video/quicktime",
                            takesLinearLight: true, compresses: false,
                            bits: $0.0.hasPrefix("prores4444") ? 12 : 10)
        }
        return formats
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
        if !isProRes {
            // The Mac app's SDR colorimetry: Display P3 primaries, the sRGB transfer, BT.709 matrix.
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
            let rate = Int(delivery.frameRate.rounded())
            var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: rate,
                                              AVVideoMaxKeyFrameIntervalKey: rate * 2]
            // "high" is the Mac app's house choice: VideoToolbox derives its own rate.
            let bitsPerPixel: Double? = ["medium": 0.08, "very-high": 0.3][delivery.quality]
            if let bitsPerPixel {
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
                            knee: delivery.shoulderKnee)
        default:
            Self.fill420(buffer, from: pixels, width: delivery.width, height: delivery.height,
                         knee: delivery.shoulderKnee)
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

    /// Linear light through the film's SDR shoulder and the sRGB transfer, 16-bit big-endian
    /// ARGB: Apple's recommended ProRes input, as the Mac app's `ProResRecording` writes it.
    private static func fillProRes(_ buffer: CVPixelBuffer, from pixels: UnsafeRawBufferPointer,
                                   width: Int, height: Int, knee: Float) {
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let developed = UnsafeBufferPointer(start: pixels.baseAddress!.assumingMemoryBound(to: Float.self),
                                            count: width * height * 4)
        let converter = FilmDisplayP3SDRConversion(shoulderKnee: knee)
        DispatchQueue.concurrentPerform(iterations: height) { y in
            let encoded = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * 4)
            defer { encoded.deallocate() }
            converter.convert(developed, from: y * width * 4, count: width * 4, into: encoded)
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                row[x * 4] = UInt16.max.bigEndian
                for c in 0..<3 { row[x * 4 + 1 + c] = code16(encoded[x * 4 + c]).bigEndian }
            }
        }
        attachSDRColor(buffer)
    }

    /// The same light as 10-bit 4:2:0 video-range BT.709 Y′CbCr, as `SDR10Recording` writes it.
    private static func fill420(_ buffer: CVPixelBuffer, from pixels: UnsafeRawBufferPointer,
                                width: Int, height: Int, knee: Float) {
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
        let developed = UnsafeBufferPointer(start: pixels.baseAddress!.assumingMemoryBound(to: Float.self),
                                            count: width * height * 4)
        let converter = FilmDisplayP3SDRConversion(shoulderKnee: knee)
        func code(_ value: Float) -> UInt16 { UInt16(min(max(value.rounded(), 0), 1023)) << 6 }
        DispatchQueue.concurrentPerform(iterations: height / 2) { cy in
            let top = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * 4)
            let bottom = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * 4)
            defer { top.deallocate(); bottom.deallocate() }
            converter.convert(developed, from: cy * 2 * width * 4, count: width * 4, into: top)
            converter.convert(developed, from: (cy * 2 + 1) * width * 4, count: width * 4, into: bottom)
            func rgb(_ row: UnsafeMutableBufferPointer<Float>, _ x: Int) -> SIMD3<Float> {
                SIMD3(row[x * 4], row[x * 4 + 1], row[x * 4 + 2])
            }
            let topLuma = luma + cy * 2 * lumaStride, bottomLuma = topLuma + lumaStride
            let chromaRow = chroma + cy * chromaStride
            for x in stride(from: 0, to: width, by: 2) {
                let encoded = SDRVideoTransfer.encode420(
                    topLeft: rgb(top, x), topRight: rgb(top, x + 1),
                    bottomLeft: rgb(bottom, x), bottomRight: rgb(bottom, x + 1))
                topLuma[x] = code(encoded.luma.x * 876 + 64)
                topLuma[x + 1] = code(encoded.luma.y * 876 + 64)
                bottomLuma[x] = code(encoded.luma.z * 876 + 64)
                bottomLuma[x + 1] = code(encoded.luma.w * 876 + 64)
                chromaRow[x] = code(encoded.u * 896 + 512)
                chromaRow[x + 1] = code(encoded.v * 896 + 512)
            }
        }
        attachSDRColor(buffer)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Center, .shouldPropagate)
    }

    private static func code16(_ value: Float) -> UInt16 {
        UInt16((min(max(value, 0), 1) * Float(UInt16.max)).rounded())
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
