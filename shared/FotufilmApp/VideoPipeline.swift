import AVFoundation
import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import Metal
import VideoToolbox

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Develops a video file frame by frame through the film engine — offline, not paced to the clock:
/// the reader hands frames as fast as the schedule develops them and the writer takes them as fast
/// as they finish.
enum VideoPipeline {
    /// Native Apple delivery codecs. ProRes remains a QuickTime-only choice at the UI boundary and
    /// receives high-bit-depth RGB, as recommended by AVAssetWriterInput.
    enum ExportCodec: Sendable {
        case h264, hevc
        case proRes422Proxy, proRes422LT, proRes422, proRes422HQ
        case proRes4444, proRes4444XQ

        var avValue: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            case .proRes422Proxy: return .proRes422Proxy
            case .proRes422LT: return .proRes422LT
            case .proRes422: return .proRes422
            case .proRes422HQ: return .proRes422HQ
            case .proRes4444: return .proRes4444
            case .proRes4444XQ:
                if #available(macOS 15.0, iOS 18.0, *) {
                    return .appleProRes4444XQ
                }
                return AVVideoCodecType(rawValue: "ap4x")
            }
        }

        var isProRes: Bool {
            switch self {
            case .h264, .hevc: return false
            case .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ,
                 .proRes4444, .proRes4444XQ:
                return true
            }
        }

        var usesTenBit420: Bool { self == .hevc }
    }

    /// The colorimetry every video surface asks its source for, and tags its output with.
    static let sdrColorProperties: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
        AVVideoTransferFunctionKey: sRGBTransferFunction,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    #if os(macOS)
    static let sRGBTransferFunction = kCVImageBufferTransferFunction_sRGB as String
    #else
    static let sRGBTransferFunction = AVVideoTransferFunction_IEC_sRGB
    #endif

    /// The colorimetry an HDR clip is written with: BT.2020 primaries, HLG,
    /// and BT.2020 non-constant luminance.
    static let hdrColorProperties: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ]

    /// The container a decode of this path asks the decoder to fill. Full float on the deep path,
    /// 8-bit BGRA otherwise.
    static func decodePixelFormat(deep: Bool) -> OSType {
        VideoDecodeDepth.Road(deepInput: deep, realtimeSchedule: !deep)
            .pixelFormat
    }

    /// The decode settings for one source contract. Explicit camera encodings and tagged HDR keep
    /// untouched code values so the app performs the one authoritative transfer conversion. SDR
    /// asks AVFoundation for Display-P3/sRGB and converts that result to the working space itself.
    static func decodeSettings(
        deep: Bool, isLog: Bool,
        sourceColor: VideoSourceColor = .colorManagedSDR
    ) -> [String: Any] {
        let format = decodePixelFormat(deep: deep)
        if isLog || (deep && sourceColor.isHDR) {
            return [kCVPixelBufferPixelFormatTypeKey as String: format]
        }
        return [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                AVVideoColorPropertiesKey: sdrColorProperties,
        ]
    }

    /// Whether the track declares an HDR transfer. Storage depth is not a range declaration.
    static func sourceIsHDR(_ asset: AVAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let formats = try? await track.load(.formatDescriptions)
        else { return false }
        return VideoSourceColor.tagged(in: formats).isHDR
    }

    /// What a developed track is compressed with. `bitsPerPixel` is what the encoder is asked to
    /// spend per pixel per frame, and nil — the house choice — asks for nothing and lets
    /// VideoToolbox derive its own rate.
    static func compressionProperties(width: Int, height: Int,
                                      frameRate: Int,
                                      bitsPerPixel: Double?,
                                      codec: ExportCodec,
                                      hdr: Bool) -> [String: Any] {
        var properties: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
        ]
        if let bitsPerPixel {
            properties[AVVideoAverageBitRateKey] =
                Int(Double(width * height * frameRate) * bitsPerPixel)
        }
        guard codec == .hevc else { return properties }
        properties[AVVideoProfileLevelKey] =
            kVTProfileLevel_HEVC_Main10_AutoLevel
        if hdr {
            properties[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] =
                kVTHDRMetadataInsertionMode_Auto
        }
        return properties
    }

    enum Failure: LocalizedError {
        case noVideoTrack
        case readerFailed(String)
        case writerFailed(String)
        case engineUnavailable
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "This file doesn’t contain a video."
            case .readerFailed:
                return "Fotufilm couldn’t read this video."
            case .writerFailed:
                return "Fotufilm couldn’t export this video."
            case .engineUnavailable:
                return "Film processing isn’t available on this device."
            case .cancelled:
                return "The export was canceled."
            }
        }
    }

    /// Shared with the export loop, which polls it between frames.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    /// A cooperative stop at frame boundaries while the app is inactive.
    final class PauseFlag: @unchecked Sendable {
        private let condition = NSCondition()
        private var paused = false

        func setPaused(_ value: Bool) {
            condition.lock()
            paused = value
            if !value { condition.broadcast() }
            condition.unlock()
        }

        /// Returns false when cancellation wins while waiting.
        func waitUntilResumed(
            isCancelled: @escaping @Sendable () -> Bool
        ) -> Bool {
            condition.lock()
            while paused {
                if isCancelled() {
                    condition.unlock()
                    return false
                }
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
            }
            condition.unlock()
            return !isCancelled()
        }
    }

    /// The clip's capture facts, as far as the file actually states them: the body that
    /// recorded it and the white balance it was shot at. Both optional and usually absent —
    /// a rewrapped MXF carries only the rewrapper's software tag, and no QuickTime key names
    /// a colour temperature at all — and absence stays nil: the profile correction skips
    /// rather than guesses.
    struct VideoCaptureMetadata: Sendable {
        var camera: CameraIdentity? = nil
        var sceneCCT: Float? = nil
    }

    /// Reads make, model and white balance from the asset: the common metadata space first
    /// (which is where QuickTime's `com.apple.quicktime.make`/`.model` surface), any other
    /// identifier that plainly names a make or model second, and, for a file on disk, Sony's
    /// embedded NonRealTimeMeta XML last — the XAVC record that names the body even when the
    /// QuickTime atoms say nothing.
    static func captureMetadata(of asset: AVAsset) async -> VideoCaptureMetadata {
        var make: String?
        var model: String?
        var cct: Float?

        let items = ((try? await asset.load(.commonMetadata)) ?? [])
            + ((try? await asset.load(.metadata)) ?? [])
        for item in items {
            guard let value = try? await item.load(.stringValue),
                  !value.isEmpty else { continue }
            if item.commonKey == .commonKeyMake {
                make = make ?? value
            } else if item.commonKey == .commonKeyModel {
                model = model ?? value
            } else if let id = item.identifier?.rawValue.lowercased() {
                if id.hasSuffix(".make") || id.hasSuffix("/make") {
                    make = make ?? value
                } else if id.hasSuffix(".model") || id.hasSuffix("/model") {
                    model = model ?? value
                }
            }
        }

        if (make == nil || model == nil || cct == nil),
           let url = (asset as? AVURLAsset)?.url, url.isFileURL,
           let sony = sonyNonRealTimeMeta(at: url) {
            make = make ?? sony.make
            model = model ?? sony.model
            cct = cct ?? sony.cct
        }

        // The profile store resolves on make *and* model; one without the other names nothing.
        let camera = (make != nil && model != nil)
            ? CameraIdentity(make: make, model: model) : nil
        return VideoCaptureMetadata(camera: camera, sceneCCT: cct)
    }

    private static func sonyNonRealTimeMeta(
        at url: URL
    ) -> (make: String?, model: String?, cct: Float?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let window = 4 << 20
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        var data = Data()
        let tailStart = size > UInt64(window) ? size - UInt64(window) : 0
        if (try? handle.seek(toOffset: tailStart)) != nil {
            data = (try? handle.read(upToCount: window)) ?? Data()
        }
        if tailStart > 0, data.range(of: Data("<NonRealTimeMeta".utf8)) == nil,
           (try? handle.seek(toOffset: 0)) != nil {
            data = (try? handle.read(upToCount: window)) ?? Data()
        }
        guard let open = data.range(of: Data("<NonRealTimeMeta".utf8)),
              let close = data.range(of: Data("</NonRealTimeMeta>".utf8),
                                     in: open.upperBound..<data.endIndex),
              let xml = String(data: data[open.lowerBound..<close.upperBound],
                               encoding: .utf8)
        else { return nil }

        func attribute(_ name: String, inTag tag: String) -> String? {
            guard let element = xml.range(of: "<" + tag),
                  let end = xml[element.upperBound...].firstIndex(of: ">")
            else { return nil }
            let inside = xml[element.upperBound..<end]
            guard let mark = inside.range(of: name + "=\""),
                  let quote = inside[mark.upperBound...].firstIndex(of: "\"")
            else { return nil }
            let value = String(inside[mark.upperBound..<quote])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        let make = attribute("manufacturer", inTag: "Device")
        let model = attribute("modelName", inTag: "Device")
        // A white balance only counts when it is a plausible kelvin number — Sony also writes
        // mode names here on some bodies, and a mode is not a temperature.
        var cct: Float?
        if let mark = xml.range(of: "name=\"WhiteBalance\""),
           let tail = xml[mark.upperBound...].range(of: "value=\""),
           let quote = xml[tail.upperBound...].firstIndex(of: "\""),
           let kelvin = Float(xml[tail.upperBound..<quote]),
           kelvin >= 1000, kelvin <= 20000 {
            cct = kelvin
        }
        guard make != nil || model != nil || cct != nil else { return nil }
        return (make, model, cct)
    }

    /// A single still for the on-screen preview, taken from early in the clip; display-oriented.
    static func posterFrame(of asset: AVAsset) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    /// One decoded source frame near the playhead, tone-mapped and oriented for display, bounded to
    /// `longestSide` on its longer edge.
    static func sourceFrame(
        of asset: AVAsset,
        at seconds: TimeInterval,
        longestSide: CGFloat,
        encoding: VideoSourceEncoding = .standard
    ) async -> CGImage? {
        if encoding.requiresExplicitDecode {
            let capture = await captureMetadata(of: asset)
            if let deep = await deepLogFrame(of: asset, at: seconds,
                                             longestSide: longestSide,
                                             encoding: encoding,
                                             capture: capture) {
                return deep
            }
            guard let shallow = await generatedFrame(of: asset, at: seconds,
                                                     longestSide: longestSide)
            else { return nil }
            return LogConverter.convertImage(shallow, encoding: encoding,
                                             camera: capture.camera,
                                             sceneCCT: capture.sceneCCT)
        }
        if let deep = await deepSourceFrame(of: asset, at: seconds,
                                            longestSide: longestSide) {
            return deep
        }
        return await generatedFrame(of: asset, at: seconds,
                                    longestSide: longestSide)
    }

    private static func generatedFrame(
        of asset: AVAsset,
        at seconds: TimeInterval,
        longestSide: CGFloat
    ) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longestSide, height: longestSide)
        generator.requestedTimeToleranceBefore =
            CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter =
            CMTime(seconds: 0.04, preferredTimescale: 600)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    /// One decoded log frame in the signal the emulsion actually wants: tightly packed scene-linear
    /// float RGBA, normalized so diffuse white lands on 1.0 and with the headroom above it intact.
    /// This is what playback puts in its input buffer, carried out of the decoder without a
    /// CoreGraphics round trip — no display render, no transfer encode, no eight-bit floor — so a
    /// held frame and a playing one reach the film through the same numbers.
    struct SceneLinearFrame: Sendable {
        var width: Int
        var height: Int
        /// Tightly packed RGBA. Scene-referred and unclamped: values above 1 are highlight.
        var pixels: [Float]
    }

    private static func withDeepFrame<T>(
        of asset: AVAsset,
        at seconds: TimeInterval,
        longestSide: CGFloat,
        isLog: Bool,
        sourceColor: VideoSourceColor = .colorManagedSDR,
        _ body: (CVPixelBuffer, CGImagePropertyOrientation) -> T?
    ) async -> T? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let width = Int(abs(naturalSize.width).rounded())
        let height = Int(abs(naturalSize.height).rounded())
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, Double(longestSide) / Double(max(width, height)))
        var settings = decodeSettings(deep: true, isLog: isLog,
                                      sourceColor: sourceColor)
        if scale < 1 {
            settings[kCVPixelBufferWidthKey as String] =
                max(2, Int((Double(width) * scale).rounded()))
            settings[kCVPixelBufferHeightKey as String] =
                max(2, Int((Double(height) * scale).rounded()))
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track,
                                              outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        // The sample is held, not just its image buffer: letting it go would hand the buffer back
        // to the decoder's pool while `body` is still reading it.
        guard let sample = output.copyNextSampleBuffer(),
              let pixels = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(pixels)
                  == kCVPixelFormatType_128RGBAFloat
        else { return nil }
        let result = body(pixels, orientation(for: transform))
        withExtendedLifetime(sample) {}
        return result
    }

    /// The playhead frame as scene-linear Rec.2020 float for the paused develop. Explicit camera
    /// encodings and standard deep/HDR clips take this path; shallow SDR remains color-managed.
    static func sceneLinearFrame(
        of asset: AVAsset,
        at seconds: TimeInterval,
        longestSide: CGFloat,
        encoding: VideoSourceEncoding
    ) async -> SceneLinearFrame? {
        let sourceColor: VideoSourceColor
        if encoding.requiresExplicitDecode {
            sourceColor = .colorManagedSDR
        } else {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let formats = try? await track.load(.formatDescriptions)
            else { return nil }
            sourceColor = VideoSourceColor.tagged(in: formats)
            let road = VideoDecodeDepth.road(
                hdr: false, log: false, sourceHDR: sourceColor.isHDR,
                sourceFormats: formats)
            guard road.deepInput else { return nil }
        }
        let capture = encoding.requiresExplicitDecode
            ? await captureMetadata(of: asset) : VideoCaptureMetadata()
        let decodedFrame: SceneLinearFrame? = await withDeepFrame(
            of: asset, at: seconds, longestSide: longestSide,
            isLog: encoding.requiresExplicitDecode, sourceColor: sourceColor,
            { pixels, orientation in
            let frameWidth = CVPixelBufferGetWidth(pixels)
            let frameHeight = CVPixelBufferGetHeight(pixels)
            var scene = [Float](
                repeating: 0, count: frameWidth * frameHeight * 4)
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let converted: Bool
            if encoding.requiresExplicitDecode {
                guard let converter = LogConverter(
                    encoding: encoding, width: frameWidth, height: frameHeight,
                    camera: capture.camera, sceneCCT: capture.sceneCCT)
                else {
                    CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
                    return nil
                }
                // The very conversion the live path runs, per pixel, on the same code values.
                converted = CVPixelBufferGetBaseAddress(pixels).map { base in
                    scene.withUnsafeMutableBufferPointer { dest in
                        converter.convertLinearPacked(
                            base, rowBytes: CVPixelBufferGetBytesPerRow(pixels),
                            into: dest.baseAddress!)
                    }
                } ?? false
            } else {
                converted = CVPixelBufferGetBaseAddress(pixels).map { base in
                    scene.withUnsafeMutableBufferPointer { destination in
                        fillSceneLinear(
                            base, rowBytes: CVPixelBufferGetBytesPerRow(pixels),
                            width: frameWidth, height: frameHeight,
                            sourceColor: sourceColor,
                            into: destination.baseAddress!)
                    }
                    return true
                } ?? false
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            guard converted else { return nil }
            return uprightScene(scene, width: frameWidth, height: frameHeight,
                                orientation: orientation)
        })
        guard var frame = decodedFrame else { return nil }
        if encoding == .standard, sourceColor.isHDR {
            // Use the same clip-level placement as playback and export. Re-estimating from the
            // held frame would make a pause change exposure when its particular scene differs.
            let gain = await standardHDRExposureGain(
                of: asset, sourceColor: sourceColor)
            if gain < 1 {
                for index in stride(from: 0, to: frame.pixels.count, by: 4) {
                    frame.pixels[index] *= gain
                    frame.pixels[index + 1] *= gain
                    frame.pixels[index + 2] *= gain
                }
            }
        }
        return frame
    }

    /// A processed HDR clip has a scene transfer but not a calibrated exposure placement. Decode
    /// one small frame through both source contracts and use the SDR rendition only to determine a
    /// uniform gain. The live and export paths then continue with inverse-transfer scene light.
    static func standardHDRExposureGain(
        of asset: AVAsset, sourceColor: VideoSourceColor
    ) async -> Float {
        guard sourceColor.isHDR else { return 1 }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let first = min(1, max(0, duration * 0.1))
        let candidates = first > 0 && abs(first - duration * 0.5) > 0.05
            ? [first, max(0, duration * 0.5)] : [first]
        for seconds in candidates {
            guard let hdr = await standardLinearFrame(
                      of: asset, at: seconds, longestSide: 256,
                      sourceColor: sourceColor),
                  let sdr = await standardLinearFrame(
                      of: asset, at: seconds, longestSide: 256,
                      sourceColor: .colorManagedSDR),
                  hdr.width == sdr.width, hdr.height == sdr.height
            else { continue }
            let gain = SceneExposureCalibration.referenceGain(
                sceneLinearHDR: hdr.pixels, linearSDRReference: sdr.pixels)
            if gain < 1 { return gain }
        }
        return 1
    }

    private static func standardLinearFrame(
        of asset: AVAsset, at seconds: TimeInterval, longestSide: CGFloat,
        sourceColor: VideoSourceColor
    ) async -> SceneLinearFrame? {
        await withDeepFrame(
            of: asset, at: seconds, longestSide: longestSide,
            isLog: false, sourceColor: sourceColor
        ) { pixels, orientation in
            let width = CVPixelBufferGetWidth(pixels)
            let height = CVPixelBufferGetHeight(pixels)
            var scene = [Float](repeating: 0, count: width * height * 4)
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let converted = CVPixelBufferGetBaseAddress(pixels).map { base in
                scene.withUnsafeMutableBufferPointer { destination in
                    fillSceneLinear(
                        base, rowBytes: CVPixelBufferGetBytesPerRow(pixels),
                        width: width, height: height,
                        sourceColor: sourceColor,
                        into: destination.baseAddress!)
                }
                return true
            } ?? false
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            guard converted else { return nil }
            return uprightScene(scene, width: width, height: height,
                                orientation: orientation)
        }
    }

    private static func uprightScene(
        _ scene: [Float], width: Int, height: Int,
        orientation: CGImagePropertyOrientation
    ) -> SceneLinearFrame {
        guard orientation != .up else {
            return SceneLinearFrame(width: width, height: height, pixels: scene)
        }
        let quarterTurn = orientation == .left || orientation == .right
        let turnedWidth = quarterTurn ? height : width
        let turnedHeight = quarterTurn ? width : height
        var rotated = [Float](
            repeating: 0, count: turnedWidth * turnedHeight * 4)
        scene.withUnsafeBufferPointer { source in
            rotated.withUnsafeMutableBufferPointer { destination in
                let src = source.baseAddress!
                let dest = destination.baseAddress!
                let chunks =
                    (height + conversionChunkRows - 1) / conversionChunkRows
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let first = chunk * conversionChunkRows
                    let last = min(height, first + conversionChunkRows)
                    for y in first..<last {
                        for x in 0..<width {
                            let turnedX: Int, turnedY: Int
                            switch orientation {
                            case .right: turnedX = height - 1 - y
                                         turnedY = x
                            case .left:  turnedX = y
                                         turnedY = width - 1 - x
                            case .down:  turnedX = width - 1 - x
                                         turnedY = height - 1 - y
                            default:     turnedX = x
                                         turnedY = y
                            }
                            let from = (y * width + x) * 4
                            let to = (turnedY * turnedWidth + turnedX) * 4
                            dest[to] = src[from]
                            dest[to + 1] = src[from + 1]
                            dest[to + 2] = src[from + 2]
                            dest[to + 3] = 1
                        }
                    }
                }
            }
        }
        return SceneLinearFrame(width: turnedWidth, height: turnedHeight,
                                pixels: rotated)
    }

    private static func fillSceneLinear(
        _ base: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int,
        sourceColor: VideoSourceColor, exposureGain: Float = 1,
        into destination: UnsafeMutablePointer<Float>
    ) {
        let chunks = (height + conversionChunkRows - 1) / conversionChunkRows
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let first = chunk * conversionChunkRows
            let last = min(height, first + conversionChunkRows)
            for y in first..<last {
                let source = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
                let output = destination + y * width * 4
                for x in 0..<width {
                    let rgb = sourceColor.linearRec2020(SIMD3(
                        source[x * 4], source[x * 4 + 1], source[x * 4 + 2]))
                    output[x * 4] = rgb.x * exposureGain
                    output[x * 4 + 1] = rgb.y * exposureGain
                    output[x * 4 + 2] = rgb.z * exposureGain
                    output[x * 4 + 3] = 1
                }
            }
        }
    }

    private static func deepLogFrame(
        of asset: AVAsset,
        at seconds: TimeInterval,
        longestSide: CGFloat,
        encoding: VideoSourceEncoding,
        capture: VideoCaptureMetadata = VideoCaptureMetadata()
    ) async -> CGImage? {
        await withDeepFrame(
            of: asset, at: seconds, longestSide: longestSide, isLog: true
        ) { pixels, orientation in
            let frameWidth = CVPixelBufferGetWidth(pixels)
            let frameHeight = CVPixelBufferGetHeight(pixels)
            guard let converter = LogConverter(encoding: encoding,
                                               width: frameWidth,
                                               height: frameHeight,
                                               camera: capture.camera,
                                               sceneCCT: capture.sceneCCT),
                  let p3 = CGColorSpace(name: CGColorSpace.displayP3)
            else { return nil }
            let rowBytes = frameWidth * 4
            var display = [UInt8](repeating: 0, count: rowBytes * frameHeight)
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let converted = CVPixelBufferGetBaseAddress(pixels).map { base in
                display.withUnsafeMutableBufferPointer { dest in
                    converter.convertDeepPacked(
                        base, rowBytes: CVPixelBufferGetBytesPerRow(pixels),
                        into: dest.baseAddress!)
                }
            } ?? false
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            guard converted,
                  let provider = CGDataProvider(data: Data(display) as CFData),
                  let image = CGImage(
                    width: frameWidth, height: frameHeight, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: rowBytes, space: p3,
                    bitmapInfo: CGBitmapInfo(
                        rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true,
                    intent: .defaultIntent)
            else { return nil }
            return upright(image, orientation, in: p3)
        }
    }

    private static let orientationContext =
        CIContext(options: [.cacheIntermediates: false])

    private static func upright(
        _ image: CGImage, _ orientation: CGImagePropertyOrientation,
        in space: CGColorSpace
    ) -> CGImage? {
        guard orientation != .up else { return image }
        let turned = CIImage(cgImage: image).oriented(orientation)
        return orientationContext.createCGImage(
            turned, from: turned.extent, format: .RGBA8, colorSpace: space)
            ?? image
    }

    private static func deepSourceFrame(
        of asset: AVAsset,
        at seconds: TimeInterval,
        longestSide: CGFloat
    ) async -> CGImage? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let formats = try? await track.load(.formatDescriptions),
              VideoDecodeDepth.isDeep(formats),
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        let width = Int(abs(naturalSize.width).rounded())
        let height = Int(abs(naturalSize.height).rounded())
        guard width > 0, height > 0 else { return nil }

        let sourceColor = VideoSourceColor.tagged(in: formats)
        // This API returns a display image. HDR is developed through `sceneLinearFrame`; asking
        // CoreGraphics to carry its raw transfer codes would make a plausible but wrong preview.
        guard !sourceColor.isHDR else { return nil }
        var settings = decodeSettings(deep: true, isLog: false,
                                      sourceColor: sourceColor)
        let scale = min(1, Double(longestSide) / Double(max(width, height)))
        if scale < 1 {
            // Even sizes, as everywhere else the decoder is asked to scale:
            // a chroma-subsampled source has no odd dimension to give.
            settings[kCVPixelBufferWidthKey as String] =
                max(2, Int((Double(width) * scale).rounded()) / 2 * 2)
            settings[kCVPixelBufferHeightKey as String] =
                max(2, Int((Double(height) * scale).rounded()) / 2 * 2)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, seconds - 2), preferredTimescale: 600),
            duration: CMTime(seconds: 4, preferredTimescale: 600))
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        // The sample is held, not just its image buffer: the buffer is the sample's, and letting
        // the sample go would hand it back to the decoder's pool while it is still being read.
        var chosen: CMSampleBuffer?
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            chosen = sample
            if CMSampleBufferGetPresentationTimeStamp(sample) >= target { break }
        }
        guard let chosen, let pixels = CMSampleBufferGetImageBuffer(chosen),
              CVPixelBufferGetPixelFormatType(pixels)
                  == kCVPixelFormatType_128RGBAFloat
        else { return nil }
        return deepStillImage(pixels, orientation: orientation(for: transform))
    }

    private static func deepStillImage(
        _ pixels: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(pixels)
        let sourceHeight = CVPixelBufferGetHeight(pixels)
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixels)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let quarterTurn = orientation == .left || orientation == .right
        let width = quarterTurn ? sourceHeight : sourceWidth
        let height = quarterTurn ? sourceWidth : sourceHeight
        guard let space = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }

        let destination = UnsafeMutableBufferPointer<UInt16>
            .allocate(capacity: width * height * 4)
        destination.initialize(repeating: 0)
        let out = destination.baseAddress!
        let chunks = (sourceHeight + conversionChunkRows - 1) / conversionChunkRows
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let first = chunk * conversionChunkRows
            let last = min(sourceHeight, first + conversionChunkRows)
            for y in first..<last {
                let row = (base + y * sourceRowBytes)
                    .assumingMemoryBound(to: Float.self)
                for x in 0..<sourceWidth {
                    let destinationX: Int, destinationY: Int
                    switch orientation {
                    case .right: destinationX = sourceHeight - 1 - y
                                 destinationY = x
                    case .left:  destinationX = y
                                 destinationY = sourceWidth - 1 - x
                    case .down:  destinationX = sourceWidth - 1 - x
                                 destinationY = sourceHeight - 1 - y
                    default:     destinationX = x
                                 destinationY = y
                    }
                    let target = (destinationY * width + destinationX) * 4
                    for channel in 0..<3 {
                        let value = row[x * 4 + channel]
                        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
                        out[target + channel] =
                            UInt16((clamped * 65535).rounded())
                    }
                    out[target + 3] = 65535
                }
            }
        }
        return PrintEncoding.makeImage(takingOwnershipOf: destination,
                                       width: width, height: height,
                                       colorSpace: space)
    }

    /// Develops one already-decoded frame with the exact stock and adjustment configuration used by
    /// the eventual movie export, through the engine's host-pointer entry point.
    static func developPreview(
        _ image: CGImage,
        stock: FilmStock,
        options: FotufilmEngine.Options,
        frameIndex: UInt64
    ) -> CGImage? {
        guard let engine = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice() else { return nil }
        // An explicit mixture takes the delivery ratio; the film's own field stands.
        var options = options
        options.completeDeliveryMottle()
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }

        let rowBytes = width * 4
        let byteCount = rowBytes * height
        guard let input = device.makeBuffer(length: byteCount,
                                            options: .storageModeShared),
              let output = device.makeBuffer(length: byteCount,
                                             options: .storageModeShared)
        else { return nil }
        // Drawn into Display P3, which is what `processRGBA8` is contracted to take — the same
        // encoded-P3 bytes the live path hands the engine. Naming sRGB here instead would spend a
        // gamut expand on the way in and a contraction on the way out, and the paused frame would
        // part company with the playing one.
        guard let context = CGContext(
            data: input.contents(),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: width, height: height))

        engine.prepare(stock: stock, options: options,
                       frameWidth: width, frameHeight: height)
        guard engine.processRGBA8(
            input: input,
            output: output,
            width: width,
            height: height,
            stock: stock,
            options: options,
            frameIndex: frameIndex
        ) else { return nil }

        let data = Data(bytes: output.contents(), count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Develops `asset` into `outputURL` with the selected native Apple codec.
    /// `FOTUFILM_EXPORT_SERIAL=1` holds the export to the relay it was: one frame in flight, each
    /// stage waiting on the last. The seam a proof is taken across — see `FilmRender.serialExport`.
    static let serialExport =
        ProcessInfo.processInfo.environment["FOTUFILM_EXPORT_SERIAL"] == "1"

    /// How many frames the export may have on the device at once.
    ///
    /// A frame is a chain of two dozen full-frame passes, and a chain has ends: the device ramps
    /// up and drains once per pass, and those gaps are what a second frame fills. Frames are
    /// independent — their own buffers, their own frame index, and the shim's execution state is
    /// per thread — so overlapping them changes when a pixel is computed and not what it is.
    ///
    /// Two, because that is where the measurement stopped paying — three and four were both
    /// slower than two on an iPhone 17 at 4K. `FOTUFILM_VIDEO_GPU_CONCURRENCY` re-opens the sweep.
    static let gpuConcurrency = max(1, ProcessInfo.processInfo
        .environment["FOTUFILM_VIDEO_GPU_CONCURRENCY"].flatMap(Int.init) ?? 2)

    /// Where an export's wall time went, charged stage by stage. `FOTUFILM_VIDEO_TIMINGS=1` asks
    /// for it; without that the loop takes one `Date()` per stage and nothing else, which against
    /// a 4K frame is noise. It is a diagnostic and not a budget: the stages overlap once the
    /// pipeline has more than one slot, so the columns sum to more than the run.
    final class StageClock: @unchecked Sendable {
        static let isEnabled =
            ProcessInfo.processInfo.environment["FOTUFILM_VIDEO_TIMINGS"] == "1"
        var decode = 0.0, convert = 0.0, develop = 0.0, append = 0.0
        var preview = 0.0
        var frames = 0
        @inline(__always) func charge(_ keyPath: ReferenceWritableKeyPath<StageClock, Double>,
                                      since start: Date) {
            guard Self.isEnabled else { return }
            self[keyPath: keyPath] += Date().timeIntervalSince(start)
        }
        @inline(__always) func mark() -> Date { Self.isEnabled ? Date() : .distantPast }
        func report(_ total: Double) {
            guard Self.isEnabled, frames > 0 else { return }
            let n = Double(frames)
            print(String(
                format: "  VideoStages over %d frames (ms/frame): "
                    + "decode %.2f · convert %.2f · develop-wait %.2f · append %.2f "
                    + "· preview %.2f | wall %.2f",
                frames, decode * 1000 / n, convert * 1000 / n,
                develop * 1000 / n, append * 1000 / n, preview * 1000 / n,
                total * 1000 / n))
            // The develop's own two halves, taken from the engine: the whole-frame measurements
            // are a host pass over the input frame, the kernel is the device's work. Which of the
            // two dominates decides whether overlapping the loop buys anything at all.
            let engine = HalideMetalFilmRenderer.FrameClock.take()
            guard engine.measure + engine.kernel > 0 else { return }
            print(String(
                format: "  VideoDevelop split (ms/frame): measure %.2f · kernel %.2f",
                engine.measure * 1000 / n, engine.kernel * 1000 / n))
        }
    }

    static func export(
        from asset: AVAsset, to outputURL: URL,
        stock: FilmStock, options: FotufilmEngine.Options,
        longEdge: Int? = nil,
        developLongEdge: Int? = nil,
        frameRate: Int? = nil,
        fileType: AVFileType = .mov,
        codec: ExportCodec? = nil,
        sourceEncoding: VideoSourceEncoding = .standard,
        camera: CameraIdentity? = nil,
        sceneCCT: Float? = nil,
        hdr: Bool = false,
        bitsPerPixel: Double? = nil,
        includeAudio: Bool = true,
        progress: @escaping @Sendable (Double, Int, Int) -> Void,
        preview: @escaping @Sendable (CGImage, CGImagePropertyOrientation) -> Void = { _, _ in },
        pause: PauseFlag? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws {
        let hdr = hdr && options.paper(for: stock).supportsHDRDelivery(for: stock)
        guard let engine = HalideMetalFilmRenderer.shared else {
            throw Failure.engineUnavailable
        }

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let outputCodec = codec ?? (hdr ? .hevc : .h264)
        guard !outputCodec.isProRes || fileType == .mov else {
            throw Failure.writerFailed("Apple ProRes requires a QuickTime movie")
        }
        let audioTrack = includeAudio
            ? try await asset.loadTracks(withMediaType: .audio).first
            : nil
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let width = Int(abs(naturalSize.width).rounded())
        let height = Int(abs(naturalSize.height).rounded())
        guard width > 0, height > 0 else { throw Failure.noVideoTrack }
        let requestedScale = longEdge.map {
            min(1, Double($0) / Double(max(width, height)))
        } ?? 1
        let outputWidth = requestedScale < 1
            ? max(2, Int((Double(width) * requestedScale).rounded()) / 2 * 2)
            : width
        let outputHeight = requestedScale < 1
            ? max(2, Int((Double(height) * requestedScale).rounded()) / 2 * 2)
            : height
        let sourceRate = Double(try await videoTrack.load(.nominalFrameRate))
        let outputRate = min(frameRate.map(Double.init) ?? sourceRate,
                             sourceRate > 0 ? sourceRate : 240)
        let totalFrames = max(1, Int((duration.seconds * outputRate).rounded()))
        let previewOrientation = Self.orientation(for: transform)
        let retimeRate: Int? = frameRate.flatMap { target in
            sourceRate <= 0 || Double(target) < sourceRate ? target : nil
        }

        let sourceFormats =
            (try? await videoTrack.load(.formatDescriptions)) ?? []
        let sourceColor = sourceEncoding.requiresExplicitDecode
            ? VideoSourceColor.colorManagedSDR
            : VideoSourceColor.tagged(in: sourceFormats)
        let road = VideoDecodeDepth.road(
            hdr: hdr || outputCodec.isProRes || outputCodec.usesTenBit420,
            log: sourceEncoding.requiresExplicitDecode,
            sourceHDR: sourceColor.isHDR, sourceFormats: sourceFormats)
        let deepInput = road.deepInput
        let sourceExposureGain = sourceEncoding == .standard && sourceColor.isHDR
            ? await standardHDRExposureGain(of: asset, sourceColor: sourceColor)
            : 1

        // The capture facts the log conversion's profile correction keys on: an explicit
        // caller override wins per fact (the headless harness may name either or both), the
        // container is asked for whatever is still missing, and a file that states nothing
        // stays nil — the correction then resolves nothing and the conversion is bit-identical
        // to the unwired build.
        var captureCamera = camera
        var captureCCT = sceneCCT
        if sourceEncoding.requiresExplicitDecode,
           captureCamera == nil || captureCCT == nil {
            let capture = await captureMetadata(of: asset)
            captureCamera = captureCamera ?? capture.camera
            captureCCT = captureCCT ?? capture.sceneCCT
        }
        let converterCamera = captureCamera
        let converterCCT = captureCCT
        // The film side of the same physical-light system: the develop integrates the stock's
        // spectral exposure under the clip's stated light. The gate inside the engine mirrors
        // the converter's — no temperature, daylight, or FOTUFILM_PROFILE_OFF leaves every
        // table bit-identical.
        var options = options
        // An explicit mixture takes the delivery ratio; the film's own field stands.
        options.completeDeliveryMottle()
        options.sceneIlluminantKelvin = options.sceneIlluminantKelvin ?? captureCCT
        // Range is a source fact, derived from the same transfer that decodes the pixels. Camera
        // log capacity is not declared content headroom; HLG and PQ are bounded transfers.
        options.sceneHeadroom = sourceEncoding.cameraEncoding?.declaredHeadroom
            ?? (sourceEncoding == .standard ? sourceColor.sceneHeadroom : 1)
        let sdrShoulderKnee = FilmSDRDelivery.shoulderKnee(
            isReversal: stock.isReversal)

        let developScale = deepInput ? 1.0 : (developLongEdge.map {
            min(1, Double($0) / Double(max(width, height)))
        } ?? 1)
        var developWidth = width
        var developHeight = height
        if developScale < 1 {
            developWidth = max(2, Int((Double(width) * developScale)
                .rounded()) / 2 * 2)
            developHeight = max(2, Int((Double(height) * developScale)
                .rounded()) / 2 * 2)
            if outputWidth < developWidth || outputHeight < developHeight {
                developWidth = outputWidth
                developHeight = outputHeight
            }
        }

        engine.prepare(stock: stock, options: options,
                       frameWidth: developWidth, frameHeight: developHeight)

        guard let metal = MTLCreateSystemDefaultDevice() else {
            throw Failure.engineUnavailable
        }
        let hybridDevelop = !deepInput && (developWidth < outputWidth
                                           || developHeight < outputHeight)
        var densitySmall: MTLBuffer?
        if hybridDevelop {
            guard let small = metal.makeBuffer(
                    length: developWidth * developHeight * 8,
                    options: .storageModeShared) else {
                throw Failure.engineUnavailable
            }
            densitySmall = small
            engine.prepare(stock: stock, options: options,
                           frameWidth: outputWidth, frameHeight: outputHeight)
        }
        // Two slots let the loop decode, convert and append one frame while the engine develops
        // another; one makes it a relay. The phone ran the relay because a second pair of
        // frame-sized buffers is memory a 4K export could not spare — measured on an iPhone 17,
        // a 4K pair is 66 MB against about 3 GB the process may still allocate, so the ceiling
        // is asked rather than assumed. Where it is not there, the relay stands.
        //
        // The overlap is worth much less here than on the Mac, and knowing that is the point:
        // the phone's 4K frame is 92% device time, so this hides about 6 ms of 98. It is taken
        // because it is free and exact, not because it is the answer.
        let bytesPerPixel = deepInput ? 16 : 4
        let frameBytesForSlot = developWidth * developHeight * bytesPerPixel
        let outputFrameBytesForSlot = hybridDevelop
            ? outputWidth * outputHeight * 4 : frameBytesForSlot
        // How many frames may be in the air at once, buffers and all. One is a relay: decode,
        // convert, wait out the whole device develop, append, and only then look at the next
        // frame. Two lets the host stages ride inside the device's shadow *and* lets a second
        // frame's passes fill the gaps at the ends of the first's chain — measured on an iPhone
        // 17 at 4K over interleaved runs, 106.9 ms a frame to 95.0, with the frames byte-for-byte
        // identical. Three was 97.1 and four 104.4: past two the frames are competing for the
        // same device rather than filling each other's gaps.
        //
        // A slot is two frame-sized buffers, 66 MB of the pair at 4K, so the ceiling is asked
        // rather than assumed; where the process cannot spare them the relay stands.
        let slotBytes = frameBytesForSlot + outputFrameBytesForSlot
        let wantedSlots = VideoPipeline.serialExport
            ? 1 : VideoPipeline.gpuConcurrency
        #if os(macOS)
        let pipelineSlots = max(2, wantedSlots)
        #else
        let affordableSlots = max(
            1, HalideMetalFilmRenderer.availableBytes() / (8 * max(1, slotBytes)))
        let pipelineSlots = hybridDevelop
            ? max(2, min(wantedSlots, affordableSlots))
            : min(wantedSlots, affordableSlots)
        #endif
        var gpuInputs: [MTLBuffer] = []
        var gpuOutputs: [MTLBuffer] = []
        let frameBytes = frameBytesForSlot
        let outputFrameBytes = outputFrameBytesForSlot
        for _ in 0..<pipelineSlots {
            guard let input = metal.makeBuffer(length: frameBytes,
                                               options: .storageModeShared),
                  let output = metal.makeBuffer(length: outputFrameBytes,
                                                options: .storageModeShared) else {
                throw Failure.engineUnavailable
            }
            gpuInputs.append(input)
            gpuOutputs.append(output)
        }
        let developedWidth = hybridDevelop ? outputWidth : developWidth
        let developedHeight = hybridDevelop ? outputHeight : developHeight
        let scaledFloatOutput: MTLBuffer?
        if deepInput && (outputWidth != width || outputHeight != height) {
            guard let buffer = metal.makeBuffer(
                length: outputWidth * outputHeight * 16,
                options: .storageModeShared) else {
                throw Failure.engineUnavailable
            }
            scaledFloatOutput = buffer
        } else {
            scaledFloatOutput = nil
        }

        let previewScale = min(
            1, 720.0 / Double(max(developedWidth, developedHeight)))
        let previewWidth = max(
            1, Int((Double(developedWidth) * previewScale).rounded()))
        let previewHeight = max(
            1, Int((Double(developedHeight) * previewScale).rounded()))

        let videoReader: AVAssetReader
        do { videoReader = try AVAssetReader(asset: asset) }
        catch { throw Failure.readerFailed(error.localizedDescription) }

        // `decodeSettings` is where all three paths that decode this file
        // ask for their container and colorimetry.
        var readerSettings = Self.decodeSettings(
            deep: deepInput, isLog: sourceEncoding.requiresExplicitDecode,
            sourceColor: sourceColor)
        if developWidth != width || developHeight != height {
            readerSettings[kCVPixelBufferWidthKey as String] = developWidth
            readerSettings[kCVPixelBufferHeightKey as String] = developHeight
        }
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack, outputSettings: readerSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard videoReader.canAdd(videoOutput) else {
            throw Failure.readerFailed("cannot read frames")
        }
        videoReader.add(videoOutput)

        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack, let reader = try? AVAssetReader(asset: asset) {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(out) {
                reader.add(out)
                reader.startReading()
                audioReader = reader
                audioOutput = out
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType) }
        catch { throw Failure.writerFailed(error.localizedDescription) }

        let compressionRate = outputRate > 0 ? outputRate : 30
        var writerSettings: [String: Any] = [
            AVVideoCodecKey: outputCodec.avValue,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
        ]
        if !outputCodec.isProRes {
            writerSettings[AVVideoColorPropertiesKey] = hdr
                ? hdrColorProperties : sdrColorProperties
            writerSettings[AVVideoCompressionPropertiesKey] = compressionProperties(
                width: outputWidth, height: outputHeight,
                frameRate: Int(compressionRate.rounded()),
                bitsPerPixel: bitsPerPixel, codec: outputCodec, hdr: hdr)
        }
        guard writer.canApply(outputSettings: writerSettings,
                              forMediaType: .video) else {
            throw Failure.writerFailed("the selected codec is unavailable on this device")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: writerSettings)
        videoInput.expectsMediaDataInRealTime = false
        var outputTransform = transform
        outputTransform.tx *= requestedScale
        outputTransform.ty *= requestedScale
        videoInput.transform = outputTransform
        var sourceBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                outputCodec.usesTenBit420
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : (outputCodec.isProRes
                       ? kCVPixelFormatType_64ARGB
                       : kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [:] as [String: Any],
        ]
        if !outputCodec.isProRes {
            sourceBufferAttributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourceBufferAttributes)
        guard writer.canAdd(videoInput) else {
            throw Failure.writerFailed("cannot write frames")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        guard writer.startWriting() else {
            throw Failure.writerFailed(writer.error?.localizedDescription ?? "start failed")
        }
        guard videoReader.startReading() else {
            throw Failure.readerFailed(videoReader.error?.localizedDescription ?? "start failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(duration.seconds, 0.0001)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let logConverter = sourceEncoding.requiresExplicitDecode
                    ? LogConverter(encoding: sourceEncoding,
                                   width: developWidth, height: developHeight,
                                   camera: converterCamera,
                                   sceneCCT: converterCCT)
                    : nil
                var previewPixels = [UInt8](repeating: 0,
                                            count: previewWidth * previewHeight * 4)
                var previewFloats = [Float](
                    repeating: 0,
                    count: deepInput ? previewWidth * previewHeight * 4 : 0)
                var outputPixels = [UInt8](
                    repeating: 0,
                    count: (outputWidth == developedWidth
                            && outputHeight == developedHeight)
                        ? 0 : outputWidth * outputHeight * 4)
                var frameIndex: UInt64 = 0
                var lastPreview = Date.distantPast
                var lastSlot = Int64(-1)
                var failure: Failure?

                // One frame on the device at a time, unless asked otherwise. A frame is a
                // chain of two dozen full-frame passes, and a chain has ends: the device ramps
                // up and drains once per pass, and a second frame's passes could be filling
                // those gaps. Frames are independent — their own buffers, their own frame index,
                // and the shim's execution state is per thread — so overlapping them cannot
                // change a pixel, only when it is computed.
                //
                let engineQueue = pipelineSlots > 1
                    ? DispatchQueue(label: "fotufilm.video.develop",
                                    qos: .userInitiated, attributes: .concurrent)
                    : DispatchQueue(label: "fotufilm.video.develop")
                final class DevelopJob: @unchecked Sendable {
                    var ok = false
                    var cancelled = false
                    var item: DispatchWorkItem!
                }
                struct Pending {
                    let job: DevelopJob
                    let slot: Int
                    let presentation: CMTime
                    let sourceSeconds: Double
                    let ordinal: Int
                }
                // Frames dispatched and not yet appended, oldest first. At most `pipelineSlots
                // - 1` are retained after each flush, which is what keeps a slot's buffers free
                // by the time the frame `pipelineSlots` later reaches for them.
                var pending: [Pending] = []
                let clock = StageClock()
                let loopStart = Date()

                func flush(_ entry: Pending) -> Failure? {
                    let waitStart = clock.mark()
                    entry.job.item.wait()
                    clock.charge(\.develop, since: waitStart)
                    if entry.job.cancelled { return .cancelled }
                    guard entry.job.ok else {
                        return .writerFailed(
                            writer.error?.localizedDescription ?? "frame develop failed")
                    }
                    while !videoInput.isReadyForMoreMediaData { usleep(1000) }
                    let appendStart = clock.mark()
                    let appended: Bool
                    if deepInput {
                        appended = appendLinearFloatFrame(
                            from: gpuOutputs[entry.slot],
                            width: width, height: height,
                            outputWidth: outputWidth, outputHeight: outputHeight,
                            scaledOutput: scaledFloatOutput,
                            adaptor: adaptor, time: entry.presentation,
                            ordinal: entry.ordinal, hdr: hdr,
                            codec: outputCodec,
                            sdrShoulderKnee: sdrShoulderKnee)
                    } else {
                        appended = appendFrame(
                            from: gpuOutputs[entry.slot],
                            width: developedWidth, height: developedHeight,
                            outputWidth: outputWidth,
                            outputHeight: outputHeight,
                            scratch: &outputPixels,
                            adaptor: adaptor, time: entry.presentation,
                            ordinal: entry.ordinal)
                    }
                    clock.charge(\.append, since: appendStart)
                    clock.frames += 1
                    guard appended else {
                        return .writerFailed(
                            writer.error?.localizedDescription ?? "frame append failed")
                    }
                    progress(min(0.999, entry.sourceSeconds / totalSeconds),
                             min(entry.ordinal, totalFrames), totalFrames)
                    let previewStart = clock.mark()
                    defer { clock.charge(\.preview, since: previewStart) }
                    if Date().timeIntervalSince(lastPreview) > 0.15,
                       let frame = deepInput
                           ? previewImageFloat(
                               from: gpuOutputs[entry.slot],
                               width: developedWidth, height: developedHeight,
                               previewWidth: previewWidth,
                               previewHeight: previewHeight,
                               scaled: &previewFloats,
                               scratch: &previewPixels,
                               sdrShoulderKnee: sdrShoulderKnee)
                           : previewImage(
                               from: gpuOutputs[entry.slot],
                               width: developedWidth, height: developedHeight,
                               previewWidth: previewWidth,
                               previewHeight: previewHeight,
                               scratch: &previewPixels) {
                        lastPreview = Date()
                        preview(frame, previewOrientation)
                    }
                    return nil
                }

                while failure == nil, videoReader.status == .reading {
                    let done = autoreleasepool { () -> Bool in
                        if let pause,
                           !pause.waitUntilResumed(isCancelled: isCancelled) {
                            videoReader.cancelReading()
                            failure = .cancelled
                            return true
                        }
                        let decodeStart = clock.mark()
                        let nextSample = videoOutput.copyNextSampleBuffer()
                        clock.charge(\.decode, since: decodeStart)
                        guard let sample = nextSample else {
                            return true
                        }
                        if isCancelled() {
                            videoReader.cancelReading()
                            failure = .cancelled
                            return true
                        }
                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
                        else { return false }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        var presentation = time
                        if let retimeRate {
                            let slot = Int64(time.seconds * Double(retimeRate))
                            if slot <= lastSlot { return false }
                            lastSlot = slot
                            presentation = CMTime(value: CMTimeValue(slot),
                                                  timescale: CMTimeScale(retimeRate))
                        }
                        let slot = Int(frameIndex % UInt64(pipelineSlots))
                        let convertStart = clock.mark()
                        let filled: Bool
                        if let logConverter {
                            filled = logConverter.convertLinear(
                                pixelBuffer, into: gpuInputs[slot])
                        } else if deepInput {
                            filled = fillLinearFloatInput(
                                pixelBuffer, into: gpuInputs[slot],
                                width: width, height: height,
                                sourceColor: sourceColor,
                                exposureGain: sourceExposureGain)
                        } else {
                            filled = fillInput(pixelBuffer, into: gpuInputs[slot],
                                               width: developWidth,
                                               height: developHeight)
                        }
                        clock.charge(\.convert, since: convertStart)
                        guard filled else {
                            failure = .writerFailed("frame convert failed")
                            return true
                        }
                        let job = DevelopJob()
                        let index = frameIndex
                        job.item = DispatchWorkItem { [job] in
                            if let pause,
                               !pause.waitUntilResumed(isCancelled: isCancelled) {
                                job.cancelled = true
                                return
                            }
                            if let densitySmall {
                                job.ok = engine.processRGBA8Head(
                                    input: gpuInputs[slot],
                                    density: densitySmall,
                                    width: developWidth, height: developHeight,
                                    stock: stock, options: options,
                                    frameIndex: index)
                                && engine.processRGBA8Tail(
                                    density: densitySmall,
                                    output: gpuOutputs[slot],
                                    width: outputWidth, height: outputHeight,
                                    densityWidth: developWidth,
                                    densityHeight: developHeight,
                                    stock: stock, options: options,
                                    frameIndex: index)
                                return
                            }
                            job.ok = deepInput
                                ? engine.processLinearFloat(
                                    input: gpuInputs[slot], output: gpuOutputs[slot],
                                    width: width, height: height, stock: stock,
                                    options: options, frameIndex: index,
                                    realtime: road.realtimeSchedule)
                                : engine.processRGBA8(
                                    input: gpuInputs[slot], output: gpuOutputs[slot],
                                    width: developWidth, height: developHeight,
                                    stock: stock,
                                    options: options, frameIndex: index)
                        }
                        engineQueue.async(execute: job.item)
                        let entry = Pending(job: job, slot: slot,
                                            presentation: presentation,
                                            sourceSeconds: time.seconds,
                                            ordinal: Int(frameIndex) + 1)
                        frameIndex += 1
                        pending.append(entry)
                        while pending.count > pipelineSlots - 1 {
                            if let f = flush(pending.removeFirst()) {
                                failure = f
                                return true
                            }
                        }
                        return false
                    }
                    if done { break }
                }
                while failure == nil, !pending.isEmpty {
                    failure = flush(pending.removeFirst())
                }
                for entry in pending { entry.job.item.wait() }
                pending.removeAll()
                videoInput.markAsFinished()
                clock.report(Date().timeIntervalSince(loopStart))
                if let failure { throw failure }
                if videoReader.status == .failed {
                    throw Failure.readerFailed(
                        videoReader.error?.localizedDescription ?? "read failed")
                }
            }
            if let audioInput, let audioOutput {
                group.addTask {
                    while audioReader?.status == .reading,
                          let sample = audioOutput.copyNextSampleBuffer() {
                        if let pause,
                           !pause.waitUntilResumed(isCancelled: isCancelled) {
                            throw Failure.cancelled
                        }
                        while !audioInput.isReadyForMoreMediaData { usleep(1000) }
                        audioInput.append(sample)
                    }
                    audioInput.markAsFinished()
                }
            }
            try await group.waitForAll()
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw Failure.writerFailed(writer.error?.localizedDescription ?? "finalize failed")
        }
        progress(1.0, totalFrames, totalFrames)
    }

    private static func previewImage(
        from gpuOutput: MTLBuffer, width: Int, height: Int,
        previewWidth: Int, previewHeight: Int, scratch: inout [UInt8]
    ) -> CGImage? {
        var full = vImage_Buffer(
            data: gpuOutput.contents(), height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: width * 4)
        let scaled = scratch.withUnsafeMutableBufferPointer { pixels -> Bool in
            var small = vImage_Buffer(
                data: pixels.baseAddress, height: vImagePixelCount(previewHeight),
                width: vImagePixelCount(previewWidth), rowBytes: previewWidth * 4)
            return vImageScale_ARGB8888(&full, &small, nil,
                                        vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard scaled else { return nil }
        let data = Data(scratch)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }
        return CGImage(
            width: previewWidth, height: previewHeight, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: previewWidth * 4, space: space,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Display orientation for a track's preferred transform: the writer stores frames in natural
    /// orientation and carries the transform, so previews have to apply the same rotation
    /// themselves.
    static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        if transform.a == 0, transform.b == 1, transform.c == -1, transform.d == 0 {
            return .right
        }
        if transform.a == 0, transform.b == -1, transform.c == 1, transform.d == 0 {
            return .left
        }
        if transform.a == -1, transform.d == -1 { return .down }
        return .up
    }

    /// Bits per component the codec actually stores.
    static func sourceBitsPerComponent(_ description: CMFormatDescription) -> Int {
        VideoDecodeDepth.bitsPerComponent(description)
    }

    /// Rows per parallel chunk for the deep-frame conversions.
    static let conversionChunkRows = 64

    /// Linear light for every 16-bit unorm code — the deep still decode lands as a 16-bit image
    /// deep still decode landing as a 16-bit image because CoreGraphics carries no deeper
    /// container. 256 KB, built once and kept.
    static let unormToLinear: [Float] = {
        (0..<65536).map { code in
            let encoded = Float(code) / 65535
            return encoded <= 0.04045
                ? encoded / 12.92
                : powf((encoded + 0.055) / 1.055, 2.4)
        }
    }()

    /// Fills the engine input from the source contract. Every branch leaves this function as
    /// scene-linear Rec.2020; no display OOTF or delivery gamut enters film exposure.
    static func fillLinearFloatInput(
        _ pixelBuffer: CVPixelBuffer, into gpuInput: MTLBuffer,
        width: Int, height: Int,
        sourceColor: VideoSourceColor = .colorManagedSDR,
        exposureGain: Float = 1
    ) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destination = gpuInput.contents().assumingMemoryBound(to: Float.self)
        fillSceneLinear(base, rowBytes: sourceRowBytes,
                        width: width, height: height,
                        sourceColor: sourceColor,
                        exposureGain: exposureGain, into: destination)
        return true
    }

    private static func appendLinearFloatFrame(
        from gpuOutput: MTLBuffer, width: Int, height: Int,
        outputWidth: Int, outputHeight: Int, scaledOutput: MTLBuffer?,
        adaptor: AVAssetWriterInputPixelBufferAdaptor, time: CMTime,
        ordinal: Int, hdr: Bool = false, codec: ExportCodec = .h264,
        sdrShoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee
    ) -> Bool {
        guard let pool = adaptor.pixelBufferPool else { return false }
        var outBufferOpt: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBufferOpt) == kCVReturnSuccess,
              let outBuffer = outBufferOpt else { return false }
        if codec.isProRes {
            let developed: UnsafePointer<Float>
            if outputWidth != width || outputHeight != height {
                guard let scaledOutput else { return false }
                var source = vImage_Buffer(
                    data: gpuOutput.contents(), height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 16)
                var destination = vImage_Buffer(
                    data: scaledOutput.contents(),
                    height: vImagePixelCount(outputHeight),
                    width: vImagePixelCount(outputWidth),
                    rowBytes: outputWidth * 16)
                guard vImageScale_ARGBFFFF(
                    &source, &destination, nil,
                    vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
                else { return false }
                developed = UnsafePointer(
                    scaledOutput.contents().assumingMemoryBound(to: Float.self))
            } else {
                developed = UnsafePointer(
                    gpuOutput.contents().assumingMemoryBound(to: Float.self))
            }
            guard ProResRecording.write(
                    print: developed, width: outputWidth, height: outputHeight,
                    hdr: hdr, sdrShoulderKnee: sdrShoulderKnee,
                    into: outBuffer)
            else { return false }
            ExportProof.add(key: ordinal, pixelBuffer: outBuffer)
            return adaptor.append(outBuffer, withPresentationTime: time)
        }
        if codec.usesTenBit420 && !hdr {
            let developed: UnsafePointer<Float>
            if outputWidth != width || outputHeight != height {
                guard let scaledOutput else { return false }
                var source = vImage_Buffer(
                    data: gpuOutput.contents(), height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 16)
                var destination = vImage_Buffer(
                    data: scaledOutput.contents(),
                    height: vImagePixelCount(outputHeight),
                    width: vImagePixelCount(outputWidth),
                    rowBytes: outputWidth * 16)
                guard vImageScale_ARGBFFFF(
                    &source, &destination, nil,
                    vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
                else { return false }
                developed = UnsafePointer(
                    scaledOutput.contents().assumingMemoryBound(to: Float.self))
            } else {
                developed = UnsafePointer(
                    gpuOutput.contents().assumingMemoryBound(to: Float.self))
            }
            guard SDR10Recording.write(
                    print: developed, width: outputWidth, height: outputHeight,
                    shoulderKnee: sdrShoulderKnee,
                    into: outBuffer)
            else { return false }
            ExportProof.add(key: ordinal, pixelBuffer: outBuffer)
            return adaptor.append(outBuffer, withPresentationTime: time)
        }
        if hdr {
            let written: Bool
            if outputWidth != width || outputHeight != height {
                guard let scaledOutput else { return false }
                var source = vImage_Buffer(
                    data: gpuOutput.contents(), height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 16)
                var destination = vImage_Buffer(
                    data: scaledOutput.contents(),
                    height: vImagePixelCount(outputHeight),
                    width: vImagePixelCount(outputWidth),
                    rowBytes: outputWidth * 16)
                guard vImageScale_ARGBFFFF(
                    &source, &destination, nil,
                    vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
                else { return false }
                written = HLGRecording.write(
                    print: scaledOutput, width: outputWidth,
                    height: outputHeight, into: outBuffer)
            } else {
                written = HLGRecording.write(
                    print: gpuOutput, width: width, height: height,
                    into: outBuffer)
            }
            guard written
            else { return false }
            ExportProof.add(key: ordinal, pixelBuffer: outBuffer)
            return adaptor.append(outBuffer, withPresentationTime: time)
        }
        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }
        guard let outBase = CVPixelBufferGetBaseAddress(outBuffer) else { return false }
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(outBuffer)
        func encode(_ developed: UnsafePointer<Float>) {
            let chunks = (outputHeight + conversionChunkRows - 1)
                / conversionChunkRows
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let first = chunk * conversionChunkRows
                let last = min(outputHeight, first + conversionChunkRows)
                for row in first..<last {
                    let source = developed + row * outputWidth * 4
                    let out = (outBase + row * destinationRowBytes)
                        .assumingMemoryBound(to: UInt8.self)
                    for x in 0..<outputWidth {
                        for channel in 0..<3 {
                            let linear = ColorScience.displayShoulder(
                                source[x * 4 + channel],
                                knee: sdrShoulderKnee)
                            out[x * 4 + 2 - channel] = UInt8(
                                (PrintEncoding.encode(linear) * 255).rounded())
                        }
                        out[x * 4 + 3] = 255
                    }
                }
            }
        }

        if outputWidth != width || outputHeight != height {
            guard let scaledOutput else { return false }
            var source = vImage_Buffer(
                data: gpuOutput.contents(), height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: width * 16)
            var destination = vImage_Buffer(
                data: scaledOutput.contents(),
                height: vImagePixelCount(outputHeight),
                width: vImagePixelCount(outputWidth),
                rowBytes: outputWidth * 16)
            guard vImageScale_ARGBFFFF(
                &source, &destination, nil,
                vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
            else { return false }
            encode(UnsafePointer(
                scaledOutput.contents().assumingMemoryBound(to: Float.self)))
        } else {
            encode(UnsafePointer(
                gpuOutput.contents().assumingMemoryBound(to: Float.self)))
        }
        ExportProof.add(key: ordinal, pixelBuffer: outBuffer)
        return adaptor.append(outBuffer, withPresentationTime: time)
    }

    private static func previewImageFloat(
        from gpuOutput: MTLBuffer, width: Int, height: Int,
        previewWidth: Int, previewHeight: Int,
        scaled: inout [Float], scratch: inout [UInt8],
        sdrShoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee
    ) -> CGImage? {
        var full = vImage_Buffer(
            data: gpuOutput.contents(), height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: width * 16)
        let ok = scaled.withUnsafeMutableBufferPointer { floats -> Bool in
            var small = vImage_Buffer(
                data: floats.baseAddress, height: vImagePixelCount(previewHeight),
                width: vImagePixelCount(previewWidth), rowBytes: previewWidth * 16)
            return vImageScale_ARGBFFFF(&full, &small, nil,
                                        vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok else { return nil }
        for index in stride(from: 0, to: previewWidth * previewHeight * 4, by: 4) {
            for channel in 0..<3 {
                let linear = ColorScience.displayShoulder(
                    scaled[index + channel], knee: sdrShoulderKnee)
                scratch[index + channel] = UInt8(
                    (PrintEncoding.encode(linear) * 255).rounded())
            }
            scratch[index + 3] = 255
        }
        let data = Data(scratch)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }
        return CGImage(
            width: previewWidth, height: previewHeight, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: previewWidth * 4, space: space,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func fillInput(
        _ pixelBuffer: CVPixelBuffer, into gpuInput: MTLBuffer,
        width: Int, height: Int
    ) -> Bool {
        let toRGBA: [UInt8] = [2, 1, 0, 3]
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return false
        }
        var source = vImage_Buffer(
            data: base, height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        var engineInput = vImage_Buffer(
            data: gpuInput.contents(), height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: width * 4)
        vImagePermuteChannels_ARGB8888(&source, &engineInput, toRGBA,
                                       vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        return true
    }

    private static func appendFrame(
        from gpuOutput: MTLBuffer, width: Int, height: Int,
        outputWidth: Int, outputHeight: Int, scratch: inout [UInt8],
        adaptor: AVAssetWriterInputPixelBufferAdaptor, time: CMTime,
        ordinal: Int
    ) -> Bool {
        guard let pool = adaptor.pixelBufferPool else { return false }
        var outBufferOpt: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBufferOpt) == kCVReturnSuccess,
              let outBuffer = outBufferOpt else { return false }
        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }
        guard let outBase = CVPixelBufferGetBaseAddress(outBuffer) else { return false }

        let toRGBA: [UInt8] = [2, 1, 0, 3]
        var developed = vImage_Buffer(
            data: gpuOutput.contents(), height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: width * 4)
        if outputWidth != width || outputHeight != height {
            let scaledAndPermuted = scratch.withUnsafeMutableBufferPointer {
                pixels -> Bool in
                var reduced = vImage_Buffer(
                    data: pixels.baseAddress, height: vImagePixelCount(outputHeight),
                    width: vImagePixelCount(outputWidth), rowBytes: outputWidth * 4)
                guard vImageScale_ARGB8888(
                    &developed, &reduced, nil,
                    vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
                else { return false }
                var destination = vImage_Buffer(
                    data: outBase, height: vImagePixelCount(outputHeight),
                    width: vImagePixelCount(outputWidth),
                    rowBytes: CVPixelBufferGetBytesPerRow(outBuffer))
                vImagePermuteChannels_ARGB8888(
                    &reduced, &destination, toRGBA,
                    vImage_Flags(kvImageNoFlags))
                return true
            }
            guard scaledAndPermuted else { return false }
        } else {
            var destination = vImage_Buffer(
                data: outBase, height: vImagePixelCount(outputHeight),
                width: vImagePixelCount(outputWidth),
                rowBytes: CVPixelBufferGetBytesPerRow(outBuffer))
            vImagePermuteChannels_ARGB8888(
                &developed, &destination, toRGBA,
                vImage_Flags(kvImageNoFlags))
        }

        ExportProof.add(key: ordinal, pixelBuffer: outBuffer)
        return adaptor.append(outBuffer, withPresentationTime: time)
    }
}
