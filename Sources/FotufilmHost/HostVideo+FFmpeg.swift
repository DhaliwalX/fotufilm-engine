#if canImport(CFotufilmVideo)
import CFotufilmVideo
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

// Movies through the system's FFmpeg (Sources/CFotufilmVideo), where there is no AVFoundation.
// The reader delivers the contracts `AVFoundationVideoSource` does; the writer the formats
// `AVFoundationVideoWriter` writes.

private func videoFailure(_ fallback: String) -> HostEngine.Failure {
    let reason = String(cString: ffv_last_error())
    return HostEngine.Failure(description: reason.isEmpty ? fallback : reason)
}

/// Opens movies with FFmpeg.
struct FFmpegVideoSources: HostVideoSourceFactory {
    static let extensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "webm", "avi", "mts", "m2ts",
                                          "ts", "mxf", "3gp", "mpg", "mpeg", "wmv", "flv", "ogv"]

    func isMovie(_ url: URL) -> Bool { Self.extensions.contains(url.pathExtension.lowercased()) }

    func open(_ url: URL) throws -> HostVideoSource { try FFmpegVideoSource(url: url) }
}

/// A movie decoded by FFmpeg: 8-bit SDR colour-managed to Display P3 as the Mac's decoder manages
/// it, deeper SDR the same in float, HDR transfers and camera log as untouched signal converted
/// here, each to scene-linear Rec.2020.
final class FFmpegVideoSource: HostVideoSource {
    let url: URL
    let width: Int
    let height: Int
    let start: Double
    let duration: Double
    let frameRate: Double
    let hasAudio: Bool
    var taggedHeadroom: Float { tagged.sceneHeadroom }
    var isDeep: Bool { deepStorage || tagged.isHDR }

    private let tagged: VideoSourceColor
    private let deepStorage: Bool
    private let camera: CameraIdentity?
    private let sceneCCT: Float?
    private let lock = NSLock()
    /// The reader the previews step through, and what it was last asked for.
    private var cursor: (reader: OpaquePointer, key: String)?

    init(url: URL) throws {
        var info = ffv_info()
        guard let reader = ffv_open(url.path, &info) else {
            throw videoFailure("This video could not be opened.")
        }
        ffv_close(reader)
        self.url = url
        width = Int(info.width)
        height = Int(info.height)
        start = info.start
        duration = info.end
        frameRate = info.frame_rate > 0 ? info.frame_rate : 30
        hasAudio = info.has_audio != 0
        deepStorage = info.bits > 8
        tagged = Self.tagged(transfer: info.transfer, primaries: info.primaries)
        // Make, model and white balance as the Mac reads them: the container's, then Sony's
        // embedded NonRealTimeMeta. A camera is both make and model or nothing.
        var make = Self.text(info.make), model = Self.text(info.model), cct: Float?
        if make == nil || model == nil || cct == nil, let sony = SonyNonRealTimeMeta.read(at: url) {
            make = make ?? sony.make
            model = model ?? sony.model
            cct = sony.cct
        }
        camera = make != nil && model != nil ? CameraIdentity(make: make, model: model) : nil
        sceneCCT = cct
    }

    deinit { if let cursor { ffv_close(cursor.reader) } }

    private static func text<T>(_ tuple: T) -> String? {
        withUnsafeBytes(of: tuple) { raw in
            let text = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return text.isEmpty ? nil : text
        }
    }

    /// The HDR transfer the stream declares, as `VideoSourceColor.tagged` reads a track's.
    private static func tagged(transfer: Int32, primaries: Int32) -> VideoSourceColor {
        let hdr: VideoSourceColor.Transfer
        switch transfer {
        case 18: hdr = .hlg
        case 16: hdr = .pq
        default: return .colorManagedSDR
        }
        switch primaries {
        case 1: return VideoSourceColor(transfer: hdr, primaries: .rec709)
        case 11, 12: return VideoSourceColor(transfer: hdr, primaries: .displayP3)
        default: return VideoSourceColor(transfer: hdr, primaries: .rec2020)
        }
    }

    // MARK: Frames

    /// How a frame leaves the decoder: the Mac decoder's roads.
    private enum Road: String {
        case managed8, managedFloat, codes
    }

    private func road(_ interpretation: HostVideoInterpretation) -> Road {
        if case .camera = interpretation { return .codes }
        if tagged.isHDR { return .codes }
        return deepStorage ? .managedFloat : .managed8
    }

    private static let readAhead = 1.0

    func frame(at seconds: Double, width: Int, height: Int,
               interpretation: HostVideoInterpretation, displayCodes: Bool) throws -> HostVideoFrame {
        lock.lock()
        defer { lock.unlock() }
        let road = road(interpretation)
        let key = "\(road)"
        let tolerance = 0.25 / frameRate
        if let cursor, cursor.key == key {
            var time = 0.0, length = 0.0
            ffv_current(cursor.reader, &time, &length)
            if seconds + tolerance >= time, seconds - time < Self.readAhead {
                var next = 0.0
                while ffv_peek(cursor.reader, &next) == 1, next <= seconds + tolerance {
                    guard ffv_step(cursor.reader) == 1 else { break }
                }
                return try frame(cursor.reader, width: width, height: height, road: road,
                                 interpretation: interpretation, displayCodes: displayCodes)
            }
        }
        if let cursor { ffv_close(cursor.reader) }
        cursor = nil
        guard let reader = ffv_open(url.path, nil) else { throw videoFailure("This video could not be read.") }
        cursor = (reader, key)
        guard ffv_seek(reader, max(start, seconds)) == 1 else {
            throw videoFailure("This video has no frame at \(seconds) s.")
        }
        return try frame(reader, width: width, height: height, road: road,
                         interpretation: interpretation, displayCodes: displayCodes)
    }

    func frames(from start: Double, to end: Double, width: Int, height: Int,
                interpretation: HostVideoInterpretation, displayCodes: Bool) throws
        -> HostVideoFrameReader {
        guard let reader = ffv_open(url.path, nil) else { throw videoFailure("This video could not be read.") }
        let road = road(interpretation)
        let opened = ffv_seek(reader, start)
        guard opened >= 0 else {
            ffv_close(reader)
            throw videoFailure("This video could not be read.")
        }
        return Frames(reader: reader, available: opened == 1, end: end) { [self] reader in
            try frame(reader, width: width, height: height, road: road,
                      interpretation: interpretation, displayCodes: displayCodes)
        }
    }

    private final class Frames: HostVideoFrameReader {
        let reader: OpaquePointer
        var available: Bool
        let end: Double
        let convert: (OpaquePointer) throws -> HostVideoFrame

        init(reader: OpaquePointer, available: Bool, end: Double,
             convert: @escaping (OpaquePointer) throws -> HostVideoFrame) {
            self.reader = reader
            self.available = available
            self.end = end
            self.convert = convert
        }

        deinit { ffv_close(reader) }

        func next() throws -> HostVideoFrame? {
            guard available else { return nil }
            var time = 0.0, length = 0.0
            ffv_current(reader, &time, &length)
            guard time < end else { return nil }
            let frame = try convert(reader)
            let stepped = ffv_step(reader)
            guard stepped >= 0 else { throw videoFailure("The video stopped decoding.") }
            available = stepped == 1
            return frame
        }
    }

    /// The reader's current frame at `width` x `height` on its road.
    private func frame(_ reader: OpaquePointer, width: Int, height: Int, road: Road,
                       interpretation: HostVideoInterpretation,
                       displayCodes: Bool) throws -> HostVideoFrame {
        var time = 0.0, length = 0.0
        ffv_current(reader, &time, &length)
        if road == .managed8 {
            var codes = [UInt8](repeating: 0, count: width * height * 4)
            let status = codes.withUnsafeMutableBytes {
                ffv_convert(reader, Int32(FFV_DISPLAY_P3_8), Int32(width), Int32(height),
                            $0.baseAddress, width * 4)
            }
            guard status == 0 else { throw videoFailure("A video frame could not be read.") }
            // The Mac's 8-bit road hands its codes over, or reads them as light (`srgbTable`).
            return displayCodes
                ? HostVideoFrame(time: time, duration: length, width: width, height: height,
                                 rgba: [], display8: codes)
                : HostVideoFrame(time: time, duration: length, width: width, height: height,
                                 rgba: HostVideoFrame.scene(display8: codes))
        }
        var rgba = [Float](repeating: 1, count: width * height * 4)
        let format = road == .managedFloat ? FFV_LINEAR_REC2020 : FFV_SIGNAL
        let status = rgba.withUnsafeMutableBytes {
            ffv_convert(reader, Int32(format), Int32(width), Int32(height), $0.baseAddress, width * 16)
        }
        guard status == 0 else { throw videoFailure("A video frame could not be read.") }
        if road == .codes {
            let pixel = pixelConversion(interpretation)
            rgba.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        let rgb = pixel(SIMD3(out[i], out[i + 1], out[i + 2]))
                        out[i] = rgb.x.isFinite ? rgb.x : 0
                        out[i + 1] = rgb.y.isFinite ? rgb.y : 0
                        out[i + 2] = rgb.z.isFinite ? rgb.z : 0
                    }
                }
            }
        }
        return HostVideoFrame(time: time, duration: length, width: width, height: height, rgba: rgba)
    }

    /// Signal to the working space, as the Mac's decoder converts its untouched code values. An
    /// HDR clip keeps its tagged placement: this platform has no SDR rendition of it to align to
    /// (the Mac's `standardExposureGain`).
    private func pixelConversion(
        _ interpretation: HostVideoInterpretation
    ) -> (SIMD3<Float>) -> SIMD3<Float> {
        guard case .camera(let encoding) = interpretation else {
            let color = tagged
            return { color.linearRec2020($0) }
        }
        let curve = encoding.curve
        let m = CameraProfileCorrection.composedGamut(
            base: encoding.gamut.toRec2020.map { Float($0) }, camera: camera, cct: sceneCCT)
            .map { $0 / 0.9 }
        let r = SIMD3(m[0], m[1], m[2]), g = SIMD3(m[3], m[4], m[5]), b = SIMD3(m[6], m[7], m[8])
        return { code in
            let linear = SIMD3(curve.linear(code.x), curve.linear(code.y), curve.linear(code.z))
            return SIMD3((r * linear).sum(), (g * linear).sum(), (b * linear).sum())
        }
    }

    // MARK: Sound

    func audioPCM(sampleRate: Int) throws -> (samples: [Int16], channels: Int)? {
        guard hasAudio else { return nil }
        var pointer: UnsafeMutablePointer<Int16>?
        var count = 0
        guard ffv_audio(url.path, Int32(sampleRate), &pointer, &count) == 1, let pointer else {
            return nil
        }
        defer { ffv_free(pointer) }
        var samples = Array(UnsafeBufferPointer(start: pointer, count: count))
        // Padded to the movie's length, so the clock runs to its last frame.
        let wanted = Int(duration * Double(sampleRate)) * 2
        if samples.count < wanted { samples.append(contentsOf: repeatElement(0, count: wanted - samples.count)) }
        return (samples, 2)
    }
}

/// Writes movies with FFmpeg.
struct FFmpegVideoWriters: HostVideoWriterFactory {
    var formats: [HostVideoFormat] {
        let codecs = ffv_codecs()
        return HostVideoFormat.deliveries.filter { format in
            codecs & (1 << FFmpegVideoWriter.codec(format.id)) != 0
        }
    }

    func writer(for format: HostVideoFormat) throws -> HostVideoWriter { FFmpegVideoWriter() }
}

final class FFmpegVideoWriter: HostVideoWriter {
    private var writer: OpaquePointer?
    private var delivery: HostVideoDelivery?
    /// The encoder's input for one frame, when it is not the developed pixels as they are.
    private var staging: UnsafeMutableRawBufferPointer?

    static func codec(_ id: String) -> Int32 {
        id == "hevc10" ? Int32(FFV_CODEC_HEVC10)
            : id.hasPrefix("prores") ? Int32(FFV_CODEC_PRORES) : Int32(FFV_CODEC_H264)
    }

    private static func proResProfile(_ id: String) -> Int32 {
        ["prores422proxy": 0, "prores422lt": 1, "prores422": 2, "prores422hq": 3,
         "prores4444": 4, "prores4444xq": 5][id] ?? 2
    }

    deinit {
        if let writer { ffv_writer_cancel(writer) }
        staging?.deallocate()
    }

    func begin(_ delivery: HostVideoDelivery) throws {
        self.delivery = delivery
        let hdr = delivery.hdr && delivery.format.carriesHDR
        let bitsPerPixel = delivery.format.compresses ? delivery.bitrate.bitsPerPixel(hdr: hdr) : nil
        let audio = (delivery.audio as? FFmpegVideoSource)?.url.path
        let opened: OpaquePointer? = delivery.url.path.withCString { path in
            func open(_ audio: UnsafePointer<CChar>?) -> OpaquePointer? {
                var config = ffv_writer_config(
                    path: path, codec: Self.codec(delivery.format.id),
                    prores_profile: Self.proResProfile(delivery.format.id),
                    width: Int32(delivery.width), height: Int32(delivery.height),
                    frame_rate: delivery.frameRate,
                    bit_rate: bitsPerPixel.map {
                        Int64(Double(delivery.width * delivery.height) * delivery.frameRate * $0)
                    } ?? 0,
                    hdr: hdr ? 1 : 0, start: delivery.range.lowerBound,
                    end: delivery.range.upperBound, audio_path: audio)
                return ffv_writer_open(&config)
            }
            guard let audio else { return open(nil) }
            return audio.withCString { open($0) }
        }
        guard let opened else { throw videoFailure("The video could not be written.") }
        writer = opened
        let pixels = ffv_writer_pixels(opened)
        if pixels != Int32(FFV_PIXELS_RGBA8) {
            // 16-bit RGBA for ProRes, or P010's luma and chroma planes for 10-bit HEVC.
            let bytes = pixels == Int32(FFV_PIXELS_RGBA64)
                ? delivery.width * delivery.height * 8
                : delivery.width * 2 * (delivery.height + delivery.height / 2)
            staging = .allocate(byteCount: bytes, alignment: 64)
        }
    }

    /// The encoder chosen, for timings and tests.
    var encoderName: String { writer.map { String(cString: ffv_writer_encoder($0)) } ?? "" }

    func append(_ pixels: UnsafeRawBufferPointer, at seconds: Double) throws {
        guard let writer, let delivery else { return }
        let (width, height) = (delivery.width, delivery.height)
        let hdr = delivery.hdr && delivery.format.carriesHDR
        var source = UnsafeRawPointer(pixels.baseAddress!)
        var rowBytes = width * 4
        if let staging {
            let base = staging.baseAddress!
            if ffv_writer_pixels(writer) == Int32(FFV_PIXELS_RGBA64) {
                HostVideoPixels.fillRGB16(pixels, width: width, height: height,
                                          knee: delivery.shoulderKnee, hdr: hdr, into: base,
                                          rowBytes: width * 8, layout: .rgbaLittleEndian)
                rowBytes = width * 8
            } else {
                let luma = base.assumingMemoryBound(to: UInt16.self)
                HostVideoPixels.fillP010(pixels, width: width, height: height,
                                         knee: delivery.shoulderKnee, hdr: hdr, luma: luma,
                                         lumaStride: width, chroma: luma + width * height,
                                         chromaStride: width)
                rowBytes = width * 2
            }
            source = UnsafeRawPointer(base)
        }
        guard ffv_writer_append(writer, source, rowBytes, seconds) == 0 else {
            throw videoFailure("The video could not be written.")
        }
    }

    func finish() throws {
        guard let writer else { return }
        self.writer = nil
        guard ffv_writer_finish(writer) == 0 else {
            if let url = delivery?.url { try? FileManager.default.removeItem(at: url) }
            throw videoFailure("The video could not be finished.")
        }
    }

    func cancel() {
        if let writer { ffv_writer_cancel(writer) }
        writer = nil
    }
}
#endif
