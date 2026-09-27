#if canImport(AVFoundation)
import AVFoundation
import CoreVideo
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif
import UniformTypeIdentifiers

/// Opens movies with AVFoundation.
struct AVFoundationVideoSources: HostVideoSourceFactory {
    func isMovie(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    func open(_ url: URL) throws -> HostVideoSource { try AVFoundationVideoSource(url: url) }
}

/// Movies decoded by AVFoundation, as the Mac app decodes them (`VideoPipeline`): 8-bit SDR
/// colour-managed to Display P3, deeper SDR the same in float, HDR transfers and camera log as
/// untouched code values converted here, each to scene-linear Rec.2020.
final class AVFoundationVideoSource: HostVideoSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let width: Int
    let height: Int
    let start: Double
    let duration: Double
    let frameRate: Double
    var hasAudio: Bool { audioTrack != nil }
    var taggedHeadroom: Float { tagged.sceneHeadroom }

    /// The stored frame's size and how the track turns it upright.
    private let storedWidth: Int
    private let storedHeight: Int
    private let orientation: Orientation
    private let tagged: VideoSourceColor
    private let deepStorage: Bool
    /// The body and white balance the file names, for the camera profile a log decode composes.
    private let camera: CameraIdentity?
    private let sceneCCT: Float?
    private var cursor: Cursor?
    private var exposureGain: Float?

    enum Orientation { case up, right, left, down }

    init(url: URL) throws {
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let asset = self.asset
        let loaded: (AVAssetTrack, AVAssetTrack?, CGSize, CGAffineTransform, Float,
                     [CMFormatDescription], CMTimeRange, CMTime, (CameraIdentity?, Float?))
        do {
            loaded = try waitFor {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw HostEngine.Failure(description: "This file doesn’t contain a video.")
                }
                let audio = try await asset.loadTracks(withMediaType: .audio).first
                let (size, transform, rate, formats, range) = try await track.load(
                    .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions,
                    .timeRange)
                let duration = try await asset.load(.duration)
                return (track, audio, size, transform, rate, formats, range, duration,
                        await Self.capture(of: asset, at: url))
            }
        } catch let failure as HostEngine.Failure {
            throw failure
        } catch {
            throw HostEngine.Failure(description: "This video could not be opened: \(error.localizedDescription)")
        }
        track = loaded.0
        audioTrack = loaded.1
        storedWidth = Int(abs(loaded.2.width).rounded())
        storedHeight = Int(abs(loaded.2.height).rounded())
        guard storedWidth > 0, storedHeight > 0 else {
            throw HostEngine.Failure(description: "This file doesn’t contain a video.")
        }
        orientation = Self.orientation(loaded.3)
        let quarterTurn = orientation == .left || orientation == .right
        width = quarterTurn ? storedHeight : storedWidth
        height = quarterTurn ? storedWidth : storedHeight
        frameRate = loaded.4 > 0 ? Double(loaded.4) : 30
        tagged = VideoSourceColor.tagged(in: loaded.5)
        deepStorage = VideoDecodeDepth.isDeep(loaded.5)
        start = max(0, loaded.6.start.seconds.isFinite ? loaded.6.start.seconds : 0)
        let end = loaded.6.end.seconds
        duration = end.isFinite && end > start ? end : max(start, loaded.7.seconds)
        (camera, sceneCCT) = loaded.8
    }

    // MARK: Frames

    /// How a frame leaves the decoder, from the source's contract.
    private enum Road: String {
        /// 8-bit SDR, colour-managed to Display P3 with the sRGB transfer.
        case managed8
        /// Deeper SDR the same way, in float.
        case managedFloat
        /// HDR transfers and camera log: code values untouched, in float.
        case codes
    }

    private func road(_ interpretation: HostVideoInterpretation) -> Road {
        if case .camera = interpretation { return .codes }
        if tagged.isHDR { return .codes }
        return deepStorage ? .managedFloat : .managed8
    }

    /// The colorimetry the Mac app asks colour-managed decodes for (`sdrColorProperties`).
    private static let managedColor: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
        AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    private func settings(_ road: Road, width: Int, height: Int) -> [String: Any] {
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                road == .managed8 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_128RGBAFloat,
        ]
        if road != .codes { settings[AVVideoColorPropertiesKey] = Self.managedColor }
        // The decoder scales in its own pass; it is asked for the stored orientation.
        let quarterTurn = orientation == .left || orientation == .right
        let (w, h) = quarterTurn ? (height, width) : (width, height)
        if w != storedWidth || h != storedHeight {
            settings[kCVPixelBufferWidthKey as String] = w
            settings[kCVPixelBufferHeightKey as String] = h
        }
        return settings
    }

    /// An open reader and where it stands: the sample showing and the one after it.
    private final class Cursor {
        let key: String
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        var current: CMSampleBuffer?
        var upcoming: CMSampleBuffer?
        var ended = false

        init(key: String, reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
            self.key = key
            self.reader = reader
            self.output = output
        }

        deinit { reader.cancelReading() }

        func pull() -> CMSampleBuffer? {
            guard !ended else { return nil }
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(sample) != nil { return sample }
            }
            ended = true
            return nil
        }
    }

    private func reader(_ road: Road, width: Int, height: Int,
                        range: CMTimeRange) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw HostEngine.Failure(description: "This video could not be read: \(error.localizedDescription)") }
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track,
                                              outputSettings: settings(road, width: width, height: height))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw HostEngine.Failure(description: "This video’s frames cannot be decoded here.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw HostEngine.Failure(description: "This video could not be read: "
                                     + (reader.error?.localizedDescription ?? "unknown error"))
        }
        return (reader, output)
    }

    /// How far ahead a request may be and still be read to rather than sought: past it,
    /// opening a reader at the time is quicker than decoding the frames between.
    private static let readAhead = 1.0

    func frame(at seconds: Double, width: Int, height: Int,
               interpretation: HostVideoInterpretation) throws -> HostVideoFrame {
        let road = road(interpretation)
        let key = "\(road)|\(width)x\(height)"
        let tolerance = 0.25 / frameRate
        if let cursor, cursor.key == key, let current = cursor.current,
           seconds + tolerance >= current.time, seconds - current.time < Self.readAhead {
            while true {
                if cursor.upcoming == nil { cursor.upcoming = cursor.pull() }
                guard let upcoming = cursor.upcoming, upcoming.time <= seconds + tolerance else { break }
                cursor.current = upcoming
                cursor.upcoming = nil
            }
        } else {
            let time = CMTime(seconds: max(start, seconds), preferredTimescale: 600_000)
            let (reader, output) = try self.reader(
                road, width: width, height: height,
                range: CMTimeRange(start: time, duration: .positiveInfinity))
            let opened = Cursor(key: key, reader: reader, output: output)
            opened.current = opened.pull()
            cursor = opened
        }
        guard let sample = cursor?.current else {
            throw HostEngine.Failure(description: "This video has no frame at \(seconds) s.")
        }
        return try convert(sample, width: width, height: height, road: road,
                           interpretation: interpretation)
    }

    func frames(from start: Double, to end: Double, width: Int, height: Int,
                interpretation: HostVideoInterpretation) throws -> HostVideoFrameReader {
        let road = road(interpretation)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000),
                                end: CMTime(seconds: end, preferredTimescale: 600_000))
        let (reader, output) = try self.reader(road, width: width, height: height, range: range)
        return Frames(cursor: Cursor(key: "", reader: reader, output: output), end: end) { sample in
            try self.convert(sample, width: width, height: height, road: road,
                             interpretation: interpretation)
        }
    }

    private final class Frames: HostVideoFrameReader {
        let cursor: Cursor
        let end: Double
        let convert: (CMSampleBuffer) throws -> HostVideoFrame

        init(cursor: Cursor, end: Double, convert: @escaping (CMSampleBuffer) throws -> HostVideoFrame) {
            self.cursor = cursor
            self.end = end
            self.convert = convert
        }

        func next() throws -> HostVideoFrame? {
            guard let sample = cursor.pull(), sample.time < end else {
                if cursor.reader.status == .failed {
                    throw HostEngine.Failure(description: "The video stopped decoding: "
                                             + (cursor.reader.error?.localizedDescription ?? ""))
                }
                return nil
            }
            return try convert(sample)
        }
    }

    // MARK: Conversion

    /// One decoded sample to upright scene-linear Rec.2020, in bands across the cores.
    private func convert(_ sample: CMSampleBuffer, width: Int, height: Int, road: Road,
                         interpretation: HostVideoInterpretation) throws -> HostVideoFrame {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw HostEngine.Failure(description: "A video frame had no pixels.")
        }
        let pixelWidth = CVPixelBufferGetWidth(buffer)
        let pixelHeight = CVPixelBufferGetHeight(buffer)
        let quarterTurn = orientation == .left || orientation == .right
        let outWidth = quarterTurn ? pixelHeight : pixelWidth
        let outHeight = quarterTurn ? pixelWidth : pixelHeight
        var rgba = [Float](repeating: 1, count: outWidth * outHeight * 4)
        let pixel = try pixelConversion(road, interpretation: interpretation)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw HostEngine.Failure(description: "A video frame could not be read.")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let orientation = self.orientation
        rgba.withUnsafeMutableBufferPointer { out in
            let out = out.baseAddress!
            let band = 32
            DispatchQueue.concurrentPerform(iterations: (pixelHeight + band - 1) / band) { index in
                var row = [SIMD3<Float>](repeating: .zero, count: pixelWidth)
                for y in (index * band)..<min(pixelHeight, (index + 1) * band) {
                    let source = base + y * rowBytes
                    if road == .managed8 {
                        let bytes = source.assumingMemoryBound(to: UInt8.self)
                        for x in 0..<pixelWidth {
                            row[x] = SIMD3(Self.srgbTable[Int(bytes[x * 4 + 2])],
                                           Self.srgbTable[Int(bytes[x * 4 + 1])],
                                           Self.srgbTable[Int(bytes[x * 4])])
                        }
                    } else {
                        let floats = source.assumingMemoryBound(to: Float.self)
                        for x in 0..<pixelWidth {
                            row[x] = SIMD3(floats[x * 4], floats[x * 4 + 1], floats[x * 4 + 2])
                        }
                    }
                    for x in 0..<pixelWidth {
                        let rgb = pixel(row[x])
                        let (ux, uy): (Int, Int)
                        switch orientation {
                        case .up: (ux, uy) = (x, y)
                        case .right: (ux, uy) = (pixelHeight - 1 - y, x)
                        case .left: (ux, uy) = (y, pixelWidth - 1 - x)
                        case .down: (ux, uy) = (pixelWidth - 1 - x, pixelHeight - 1 - y)
                        }
                        let i = (uy * outWidth + ux) * 4
                        out[i] = rgb.x.isFinite ? rgb.x : 0
                        out[i + 1] = rgb.y.isFinite ? rgb.y : 0
                        out[i + 2] = rgb.z.isFinite ? rgb.z : 0
                    }
                }
            }
        }
        let duration = CMSampleBufferGetDuration(sample).seconds
        return HostVideoFrame(time: sample.time,
                              duration: duration.isFinite && duration > 0 ? duration : 1 / frameRate,
                              width: outWidth, height: outHeight, rgba: rgba)
    }

    /// Linear light for every 8-bit sRGB code.
    private static let srgbTable: [Float] = (0..<256).map { ColorScience.srgbToLinear(Float($0) / 255) }

    /// The per-pixel step from what the decoder hands over to the working space. The managed
    /// 8-bit road arrives already linearised through `srgbTable`.
    private func pixelConversion(
        _ road: Road, interpretation: HostVideoInterpretation
    ) throws -> (SIMD3<Float>) -> SIMD3<Float> {
        switch (road, interpretation) {
        case (.managed8, _):
            return { ColorScience.linearDisplayP3ToRec2020($0) }
        case (.managedFloat, _):
            let color = VideoSourceColor.colorManagedSDR
            return { color.linearRec2020($0) }
        case (.codes, .standard):
            // A processed HDR clip keeps one clip-wide exposure placement (the Mac app's
            // `standardHDRExposureGain`), so pausing never changes exposure.
            let color = tagged, gain = try standardExposureGain()
            return { color.linearRec2020($0) * gain }
        case (.codes, .camera(let encoding)):
            // The Mac app's `LogConverter`: the exact inverse curve, the recorded gamut with the
            // camera's profile composed in, and diffuse white (0.9) placed at 1.
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
    }

    /// Decodes one small frame through both source contracts and keeps only the gain that
    /// places the HDR rendition's middle where the platform's SDR rendition puts it.
    private func standardExposureGain() throws -> Float {
        if let exposureGain { return exposureGain }
        var gain: Float = 1
        let first = min(1, max(start, duration * 0.1))
        let scale = min(1, 256 / Double(max(width, height)))
        let (w, h) = (max(2, Int(Double(width) * scale)), max(2, Int(Double(height) * scale)))
        for seconds in [first, max(start, duration * 0.5)] {
            let range = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600_000),
                                    duration: .positiveInfinity)
            func linear(_ road: Road, _ color: VideoSourceColor) throws -> [Float]? {
                let (reader, output) = try self.reader(road, width: w, height: h, range: range)
                let cursor = Cursor(key: "", reader: reader, output: output)
                guard let sample = cursor.pull(), let buffer = CMSampleBufferGetImageBuffer(sample),
                      CVPixelBufferGetWidth(buffer) * CVPixelBufferGetHeight(buffer) > 0 else { return nil }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
                let (pw, ph) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
                var out = [Float](repeating: 1, count: pw * ph * 4)
                for y in 0..<ph {
                    let row = (base + y * CVPixelBufferGetBytesPerRow(buffer))
                        .assumingMemoryBound(to: Float.self)
                    for x in 0..<pw {
                        let rgb = color.linearRec2020(SIMD3(row[x * 4], row[x * 4 + 1], row[x * 4 + 2]))
                        out[(y * pw + x) * 4] = rgb.x
                        out[(y * pw + x) * 4 + 1] = rgb.y
                        out[(y * pw + x) * 4 + 2] = rgb.z
                    }
                }
                return out
            }
            guard let hdr = try linear(.codes, tagged),
                  let sdr = try linear(.managedFloat, .colorManagedSDR), hdr.count == sdr.count
            else { continue }
            let found = SceneExposureCalibration.referenceGain(sceneLinearHDR: hdr,
                                                               linearSDRReference: sdr)
            if found < 1 { gain = found; break }
        }
        exposureGain = gain
        return gain
    }

    // MARK: Sound

    func audioPCM(sampleRate: Int) throws -> (samples: [Int16], channels: Int)? {
        guard let audioTrack else { return nil }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { return nil }
        let channels = 2
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples: [Int16] = []
        samples.reserveCapacity(Int(duration * Double(sampleRate * channels)) + 4096)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = samples.count
            samples.append(contentsOf: repeatElement(0, count: length / 2))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length / 2 * 2,
                                               destination: raw.baseAddress! + count * 2)
            }
        }
        guard reader.status == .completed else { return nil }
        // Pad to the movie's length, so the clock runs to its last frame.
        let wanted = Int(duration * Double(sampleRate)) * channels
        if samples.count < wanted { samples.append(contentsOf: repeatElement(0, count: wanted - samples.count)) }
        return (samples, channels)
    }

    // MARK: Metadata

    static func orientation(_ transform: CGAffineTransform) -> Orientation {
        if transform.a == 0, transform.b == 1, transform.c == -1, transform.d == 0 { return .right }
        if transform.a == 0, transform.b == -1, transform.c == 1, transform.d == 0 { return .left }
        if transform.a == -1, transform.d == -1 { return .down }
        return .up
    }

    /// Make, model and white balance as the Mac app reads them (`VideoPipeline.captureMetadata`):
    /// the common metadata first, then Sony's embedded NonRealTimeMeta. A camera is both make and
    /// model or nothing.
    private static func capture(of asset: AVAsset, at url: URL) async -> (CameraIdentity?, Float?) {
        var make: String?, model: String?, cct: Float?
        let items = ((try? await asset.load(.commonMetadata)) ?? [])
            + ((try? await asset.load(.metadata)) ?? [])
        for item in items {
            guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
            if item.commonKey == .commonKeyMake { make = make ?? value }
            else if item.commonKey == .commonKeyModel { model = model ?? value }
            else if let id = item.identifier?.rawValue.lowercased() {
                if id.hasSuffix(".make") || id.hasSuffix("/make") { make = make ?? value }
                else if id.hasSuffix(".model") || id.hasSuffix("/model") { model = model ?? value }
            }
        }
        if make == nil || model == nil || cct == nil, let sony = SonyNonRealTimeMeta.read(at: url) {
            make = make ?? sony.make
            model = model ?? sony.model
            cct = sony.cct
        }
        return (make != nil && model != nil ? CameraIdentity(make: make, model: model) : nil, cct)
    }
}

private extension CMSampleBuffer {
    var time: Double { CMSampleBufferGetPresentationTimeStamp(self).seconds }
}

/// Runs AVFoundation's asynchronous loading to completion on the calling thread, which is the
/// engine's own and never the main one.
func waitFor<T>(_ body: @escaping () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task.detached {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result!.get()
}
#endif
